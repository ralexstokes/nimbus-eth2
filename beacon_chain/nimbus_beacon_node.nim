# beacon_chain
# Copyright (c) 2018-2020 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  std/[os, tables, strutils, sequtils, times, math, terminal, osproc, random],

  # Nimble packages
  stew/[objects, byteutils, endians2, io2], stew/shims/macros,
  chronos, confutils, metrics, json_rpc/[rpcserver, jsonmarshal],
  chronicles, bearssl, blscurve,
  json_serialization/std/[options, sets, net], serialization/errors,

  eth/[keys, async_utils],
  eth/db/[kvstore, kvstore_sqlite3],
  eth/p2p/enode, eth/p2p/discoveryv5/[protocol, enr],

  # Local modules
  ./rpc/[beacon_api, config_api, debug_api, event_api, nimbus_api, node_api,
    validator_api],
  spec/[datatypes, digest, crypto, beaconstate, helpers, network, presets],
  spec/[weak_subjectivity],
  conf, time, beacon_chain_db, validator_pool, extras,
  attestation_pool, exit_pool, eth2_network, eth2_discovery,
  beacon_node_common, beacon_node_types, beacon_node_status,
  block_pools/[chain_dag, quarantine, clearance, block_pools_types],
  nimbus_binary_common, network_metadata,
  eth1_monitor, version, ssz/[merkleization], merkle_minimal,
  sync_protocol, request_manager, keystore_management, interop, statusbar,
  sync_manager, validator_duties, filepath,
  validator_slashing_protection, ./eth2_processor

const
  hasPrompt = not defined(withoutPrompt)

type
  RpcServer* = RpcHttpServer

template init(T: type RpcHttpServer, ip: ValidIpAddress, port: Port): T =
  newRpcHttpServer([initTAddress(ip, port)])

# https://github.com/ethereum/eth2.0-metrics/blob/master/metrics.md#interop-metrics
declareGauge beacon_slot,
  "Latest slot of the beacon chain state"

# Finalization tracking
declareGauge finalization_delay,
  "Epoch delay between scheduled epoch and finalized epoch"

declareGauge ticks_delay,
  "How long does to take to run the onSecond loop"

logScope: topics = "beacnde"

func enrForkIdFromState(state: BeaconState): ENRForkID =
  let
    forkVer = state.fork.current_version
    forkDigest = compute_fork_digest(forkVer, state.genesis_validators_root)

  ENRForkID(
    fork_digest: forkDigest,
    next_fork_version: forkVer,
    next_fork_epoch: FAR_FUTURE_EPOCH)

proc init*(T: type BeaconNode,
           rng: ref BrHmacDrbgContext,
           conf: BeaconNodeConf,
           genesisStateContents: ref string,
           eth1Network: Option[Eth1Network]): Future[BeaconNode] {.async.} =
  let
    netKeys = getPersistentNetKeys(rng[], conf)
    nickname = if conf.nodeName == "auto": shortForm(netKeys)
               else: conf.nodeName
    db = BeaconChainDB.init(conf.runtimePreset, conf.databaseDir)

  var
    eth1Monitor: Eth1Monitor
    genesisState, checkpointState: ref BeaconState
    checkpointBlock: SignedBeaconBlock

  if conf.finalizedCheckpointState.isSome:
    let checkpointStatePath = conf.finalizedCheckpointState.get.string
    checkpointState = try:
      newClone(SSZ.loadFile(checkpointStatePath, BeaconState))
    except SerializationError as err:
      fatal "Checkpoint state deserialization failed",
            err = formatMsg(err, checkpointStatePath)
      quit 1
    except CatchableError as err:
      fatal "Failed to read checkpoint state file", err = err.msg
      quit 1

    if conf.finalizedCheckpointBlock.isNone:
      if checkpointState.slot > 0:
        fatal "Specifying a non-genesis --finalized-checkpoint-state requires specifying --finalized-checkpoint-block as well"
        quit 1
    else:
      let checkpointBlockPath = conf.finalizedCheckpointBlock.get.string
      try:
        checkpointBlock = SSZ.loadFile(checkpointBlockPath, SignedBeaconBlock)
      except SerializationError as err:
        fatal "Invalid checkpoint block", err = err.formatMsg(checkpointBlockPath)
        quit 1
      except IOError as err:
        fatal "Failed to load the checkpoint block", err = err.msg
        quit 1
  elif conf.finalizedCheckpointBlock.isSome:
    # TODO We can download the state from somewhere in the future relying
    #      on the trusted `state_root` appearing in the checkpoint block.
    fatal "--finalized-checkpoint-block cannot be specified without --finalized-checkpoint-state"
    quit 1

  if not ChainDAGRef.isInitialized(db):
    var
      tailState: ref BeaconState
      tailBlock: SignedBeaconBlock

    if genesisStateContents == nil and checkpointState == nil:
      # This is a fresh start without a known genesis state
      # (most likely, it hasn't arrived yet). We'll try to
      # obtain a genesis through the Eth1 deposits monitor:
      if conf.web3Url.len == 0:
        fatal "Web3 URL not specified"
        quit 1

      if conf.depositContractAddress.isNone:
        fatal "Deposit contract address not specified"
        quit 1

      if conf.depositContractDeployedAt.isNone:
        # When we don't have a known genesis state, the network metadata
        # must specify the deployment block of the contract.
        fatal "Deposit contract deployment block not specified"
        quit 1

      # TODO Could move this to a separate "GenesisMonitor" process or task
      #      that would do only this - see Paul's proposal for this.
      let eth1MonitorRes = await Eth1Monitor.init(
        db,
        conf.runtimePreset,
        conf.web3Url,
        conf.depositContractAddress.get,
        conf.depositContractDeployedAt.get,
        eth1Network)

      if eth1MonitorRes.isErr:
        fatal "Failed to start Eth1 monitor",
              reason = eth1MonitorRes.error,
              web3Url = conf.web3Url,
              depositContractAddress = conf.depositContractAddress.get,
              depositContractDeployedAt = conf.depositContractDeployedAt.get
        quit 1
      else:
        eth1Monitor = eth1MonitorRes.get

      genesisState = await eth1Monitor.waitGenesis()
      if bnStatus == BeaconNodeStatus.Stopping:
        return nil

      tailState = genesisState
      tailBlock = get_initial_beacon_block(genesisState[])

      notice "Eth2 genesis state detected",
        genesisTime = genesisState.genesisTime,
        eth1Block = genesisState.eth1_data.block_hash,
        totalDeposits = genesisState.eth1_data.deposit_count

    elif genesisStateContents == nil:
      if checkpointState.slot == GENESIS_SLOT:
        genesisState = checkpointState
        tailState = checkpointState
        tailBlock = get_initial_beacon_block(genesisState[])
      else:
        fatal "State checkpoints cannot be provided for a network without a known genesis state"
        quit 1
    else:
      try:
        genesisState = newClone(SSZ.decode(genesisStateContents[], BeaconState))
      except CatchableError as err:
        raiseAssert "The baked-in state must be valid"

      if checkpointState != nil:
        tailState = checkpointState
        tailBlock = checkpointBlock
      else:
        tailState = genesisState
        tailBlock = get_initial_beacon_block(genesisState[])

    try:
      ChainDAGRef.preInit(db, genesisState[], tailState[], tailBlock)
      doAssert ChainDAGRef.isInitialized(db), "preInit should have initialized db"
    except CatchableError as e:
      error "Failed to initialize database", err = e.msg
      quit 1

  # TODO(zah) check that genesis given on command line (if any) matches database
  let
    chainDagFlags = if conf.verifyFinalization: {verifyFinalization}
                     else: {}
    chainDag = init(ChainDAGRef, conf.runtimePreset, db, chainDagFlags)
    beaconClock = BeaconClock.init(chainDag.headState.data.data)
    quarantine = QuarantineRef()

  if conf.weakSubjectivityCheckpoint.isSome:
    let
      currentSlot = beaconClock.now.slotOrZero
      isCheckpointStale = not is_within_weak_subjectivity_period(
        currentSlot,
        chainDag.headState.data.data,
        conf.weakSubjectivityCheckpoint.get)

    if isCheckpointStale:
      error "Weak subjectivity checkpoint is stale",
            currentSlot,
            checkpoint = conf.weakSubjectivityCheckpoint.get,
            headStateSlot = chainDag.headState.data.data.slot
      quit 1

  if checkpointState != nil:
    chainDag.setTailState(checkpointState[], checkpointBlock)

  if eth1Monitor.isNil and
     conf.web3Url.len > 0 and
     conf.depositContractAddress.isSome and
     conf.depositContractDeployedAt.isSome:
    # TODO(zah) if we don't have any validators attached,
    #           we don't need a mainchain monitor
    let eth1MonitorRes = await Eth1Monitor.init(
      db,
      conf.runtimePreset,
      conf.web3Url,
      conf.depositContractAddress.get,
      conf.depositContractDeployedAt.get,
      eth1Network)

    if eth1MonitorRes.isErr:
      error "Failed to start Eth1 monitor",
            reason = eth1MonitorRes.error,
            web3Url = conf.web3Url,
            depositContractAddress = conf.depositContractAddress.get,
            depositContractDeployedAt = conf.depositContractDeployedAt.get
    else:
      eth1Monitor = eth1MonitorRes.get

  let rpcServer = if conf.rpcEnabled:
    RpcServer.init(conf.rpcAddress, conf.rpcPort)
  else:
    nil

  let
    enrForkId = enrForkIdFromState(chainDag.headState.data.data)
    topicBeaconBlocks = getBeaconBlocksTopic(enrForkId.forkDigest)
    topicAggregateAndProofs = getAggregateAndProofsTopic(enrForkId.forkDigest)
    network = createEth2Node(rng, conf, netKeys, enrForkId)
    attestationPool = newClone(AttestationPool.init(chainDag, quarantine))
    exitPool = newClone(ExitPool.init(chainDag, quarantine))
  var res = BeaconNode(
    nickname: nickname,
    graffitiBytes: if conf.graffiti.isSome: conf.graffiti.get.GraffitiBytes
                   else: defaultGraffitiBytes(),
    network: network,
    netKeys: netKeys,
    db: db,
    config: conf,
    chainDag: chainDag,
    quarantine: quarantine,
    attestationPool: attestationPool,
    exitPool: exitPool,
    eth1Monitor: eth1Monitor,
    beaconClock: beaconClock,
    rpcServer: rpcServer,
    forkDigest: enrForkId.forkDigest,
    topicBeaconBlocks: topicBeaconBlocks,
    topicAggregateAndProofs: topicAggregateAndProofs,
  )

  res.attachedValidators = ValidatorPool.init(
    SlashingProtectionDB.init(
      chainDag.headState.data.data.genesis_validators_root,
      kvStore SqStoreRef.init(conf.validatorsDir(), "slashing_protection").tryGet()
    )
  )

  proc getWallTime(): BeaconTime = res.beaconClock.now()

  res.processor = Eth2Processor.new(
    conf, chainDag, attestationPool, exitPool, quarantine, getWallTime)

  res.requestManager = RequestManager.init(
    network, res.processor.blocksQueue)

  if res.config.inProcessValidators:
    res.addLocalValidators()
  else:
    let cmd = getAppDir() / "nimbus_signing_process".addFileExt(ExeExt)
    let args = [$res.config.validatorsDir, $res.config.secretsDir]
    let workdir = io2.getCurrentDir().tryGet()
    res.vcProcess = startProcess(cmd, workdir, args)
    res.addRemoteValidators()

  # This merely configures the BeaconSync
  # The traffic will be started when we join the network.
  network.initBeaconSync(chainDag, enrForkId.forkDigest)
  return res

func verifyFinalization(node: BeaconNode, slot: Slot) =
  # Epoch must be >= 4 to check finalization
  const SETTLING_TIME_OFFSET = 1'u64
  let epoch = slot.compute_epoch_at_slot()

  # Don't static-assert this -- if this isn't called, don't require it
  doAssert SLOTS_PER_EPOCH > SETTLING_TIME_OFFSET

  # Intentionally, loudly assert. Point is to fail visibly and unignorably
  # during testing.
  if epoch >= 4 and slot mod SLOTS_PER_EPOCH > SETTLING_TIME_OFFSET:
    let finalizedEpoch =
      node.chainDag.finalizedHead.slot.compute_epoch_at_slot()
    # Finalization rule 234, that has the most lag slots among the cases, sets
    # state.finalized_checkpoint = old_previous_justified_checkpoint.epoch + 3
    # and then state.slot gets incremented, to increase the maximum offset, if
    # finalization occurs every slot, to 4 slots vs scheduledSlot.
    doAssert finalizedEpoch + 4 >= epoch

proc installAttestationSubnetHandlers(node: BeaconNode, subnets: set[uint8]) =
  var attestationSubscriptions: seq[Future[void]] = @[]

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#attestations-and-aggregation
  for subnet in subnets:
    attestationSubscriptions.add(node.network.subscribe(
      getAttestationTopic(node.forkDigest, subnet)))

  waitFor allFutures(attestationSubscriptions)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#metadata
  node.network.metadata.seq_number += 1
  for subnet in subnets:
    node.network.metadata.attnets[subnet] = true

proc cycleAttestationSubnets(node: BeaconNode, slot: Slot) =
  static: doAssert RANDOM_SUBNETS_PER_VALIDATOR == 1

  let epochParity = slot.epoch mod 2
  var attachedValidators: seq[ValidatorIndex]
  for validatorIndex in 0 ..< node.chainDag.headState.data.data.validators.len:
    if node.getAttachedValidator(
        node.chainDag.headState.data.data, validatorIndex.ValidatorIndex) != nil:
      attachedValidators.add validatorIndex.ValidatorIndex

  if attachedValidators.len == 0:
    return

  let (newAttestationSubnets, expiringSubnets, newSubnets) =
    get_attestation_subnet_changes(
      node.chainDag.headState.data.data, attachedValidators,
      node.attestationSubnets, slot.epoch)

  node.attestationSubnets = newAttestationSubnets
  debug "Attestation subnets",
    expiring_subnets = expiringSubnets,
    current_epoch_subnets =
      node.attestationSubnets.subscribedSubnets[1 - epochParity],
    upcoming_subnets = node.attestationSubnets.subscribedSubnets[epochParity],
    new_subnets = newSubnets,
    stability_subnet = node.attestationSubnets.stabilitySubnet,
    stability_subnet_expiration_epoch =
      node.attestationSubnets.stabilitySubnetExpirationEpoch

  block:
    var unsubscriptions: seq[Future[void]] = @[]
    for expiringSubnet in expiringSubnets:
      unsubscriptions.add(node.network.unsubscribe(
        getAttestationTopic(node.forkDigest, expiringSubnet)))

    waitFor allFutures(unsubscriptions)

    # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#metadata
    # The race condition window is smaller by placing the fast, local, and
    # synchronous operation after a variable-latency, asynchronous action.
    node.network.metadata.seq_number += 1
    for expiringSubnet in expiringSubnets:
      node.network.metadata.attnets[expiringSubnet] = false

  node.installAttestationSubnetHandlers(newSubnets)

  block:
    let subscribed_subnets =
      node.attestationSubnets.subscribedSubnets[0] +
      node.attestationSubnets.subscribedSubnets[1] +
      {node.attestationSubnets.stabilitySubnet.uint8}
    for subnet in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
      doAssert node.network.metadata.attnets[subnet] ==
        (subnet in subscribed_subnets)

proc getAttestationHandlers(node: BeaconNode): Future[void] =
  var initialSubnets: set[uint8]
  for i in 0'u8 ..< ATTESTATION_SUBNET_COUNT:
    initialSubnets.incl i
  node.installAttestationSubnetHandlers(initialSubnets)

  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/validator.md#phase-0-attestation-subnet-stability
  let wallEpoch =  node.beaconClock.now().slotOrZero().epoch
  node.attestationSubnets.stabilitySubnet = rand(ATTESTATION_SUBNET_COUNT - 1).uint64
  node.attestationSubnets.stabilitySubnetExpirationEpoch =
    wallEpoch + getStabilitySubnetLength()

  # Sets the "current" and "future" attestation subnets. One of these gets
  # replaced by get_attestation_subnet_changes() immediately.
  node.attestationSubnets.subscribedSubnets[0] = initialSubnets
  node.attestationSubnets.subscribedSubnets[1] = initialSubnets

  node.network.subscribe(getAggregateAndProofsTopic(node.forkDigest))

proc addMessageHandlers(node: BeaconNode): Future[void] =
  allFutures(
    # As a side-effect, this gets the attestation subnets too.
    node.network.subscribe(node.topicBeaconBlocks),
    node.network.subscribe(getAttesterSlashingsTopic(node.forkDigest)),
    node.network.subscribe(getProposerSlashingsTopic(node.forkDigest)),
    node.network.subscribe(getVoluntaryExitsTopic(node.forkDigest)),

    node.getAttestationHandlers()
  )

func getTopicSubscriptionEnabled(node: BeaconNode): bool =
  node.attestationSubnets.subscribedSubnets[0].len +
  node.attestationSubnets.subscribedSubnets[1].len > 0

proc removeMessageHandlers(node: BeaconNode): Future[void] =
  node.attestationSubnets.subscribedSubnets[0] = {}
  node.attestationSubnets.subscribedSubnets[1] = {}
  doAssert not node.getTopicSubscriptionEnabled()

  var unsubscriptions = mapIt(
    [getBeaconBlocksTopic(node.forkDigest),
     getVoluntaryExitsTopic(node.forkDigest),
     getProposerSlashingsTopic(node.forkDigest),
     getAttesterSlashingsTopic(node.forkDigest),
     getAggregateAndProofsTopic(node.forkDigest)],
    node.network.unsubscribe(it))

  for subnet in 0'u64 ..< ATTESTATION_SUBNET_COUNT:
    unsubscriptions.add node.network.unsubscribe(
      getAttestationTopic(node.forkDigest, subnet))

  allFutures(unsubscriptions)

proc onSlotStart(node: BeaconNode, lastSlot, scheduledSlot: Slot) {.async.} =
  ## Called at the beginning of a slot - usually every slot, but sometimes might
  ## skip a few in case we're running late.
  ## lastSlot: the last slot that we successfully processed, so we know where to
  ##           start work from
  ## scheduledSlot: the slot that we were aiming for, in terms of timing
  let
    # The slot we should be at, according to the clock
    beaconTime = node.beaconClock.now()
    wallSlot = beaconTime.toSlot()
    finalizedEpoch =
      node.chainDag.finalizedHead.blck.slot.compute_epoch_at_slot()

  info "Slot start",
    lastSlot = shortLog(lastSlot),
    scheduledSlot = shortLog(scheduledSlot),
    beaconTime = shortLog(beaconTime),
    peers = len(node.network.peerPool),
    head = shortLog(node.chainDag.head),
    headEpoch = shortLog(node.chainDag.head.slot.compute_epoch_at_slot()),
    finalized = shortLog(node.chainDag.finalizedHead.blck),
    finalizedEpoch = shortLog(finalizedEpoch)

  # Check before any re-scheduling of onSlotStart()
  checkIfShouldStopAtEpoch(scheduledSlot, node.config.stopAtEpoch)

  if not wallSlot.afterGenesis or (wallSlot.slot < lastSlot):
    let
      slot =
        if wallSlot.afterGenesis: wallSlot.slot
        else: GENESIS_SLOT
      nextSlot = slot + 1 # At least GENESIS_SLOT + 1!

    # This can happen if the system clock changes time for example, and it's
    # pretty bad
    # TODO shut down? time either was or is bad, and PoS relies on accuracy..
    warn "Beacon clock time moved back, rescheduling slot actions",
      beaconTime = shortLog(beaconTime),
      lastSlot = shortLog(lastSlot),
      scheduledSlot = shortLog(scheduledSlot),
      nextSlot = shortLog(nextSlot)

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      asyncCheck node.onSlotStart(slot, nextSlot)

    return

  let
    slot = wallSlot.slot # afterGenesis == true!
    nextSlot = slot + 1

  beacon_slot.set slot.int64
  finalization_delay.set scheduledSlot.epoch.int64 - finalizedEpoch.int64

  if node.config.verifyFinalization:
    verifyFinalization(node, scheduledSlot)

  if slot > lastSlot + SLOTS_PER_EPOCH:
    # We've fallen behind more than an epoch - there's nothing clever we can
    # do here really, except skip all the work and try again later.
    # TODO how long should the period be? Using an epoch because that's roughly
    #      how long attestations remain interesting
    # TODO should we shut down instead? clearly we're unable to keep up
    warn "Unable to keep up, skipping ahead",
      lastSlot = shortLog(lastSlot),
      slot = shortLog(slot),
      nextSlot = shortLog(nextSlot),
      scheduledSlot = shortLog(scheduledSlot)

    addTimer(saturate(node.beaconClock.fromNow(nextSlot))) do (p: pointer):
      # We pass the current slot here to indicate that work should be skipped!
      asyncCheck node.onSlotStart(slot, nextSlot)
    return

  # Whatever we do during the slot, we need to know the head, because this will
  # give us a state to work with and thus a shuffling.
  # TODO if the head is very old, that is indicative of something being very
  #      wrong - us being out of sync or disconnected from the network - need
  #      to consider what to do in that case:
  #      * nothing - the other parts of the application will reconnect and
  #                  start listening to broadcasts, learn a new head etc..
  #                  risky, because the network might stall if everyone does
  #                  this, because no blocks will be produced
  #      * shut down - this allows the user to notice and take action, but is
  #                    kind of harsh
  #      * keep going - we create blocks and attestations as usual and send them
  #                     out - if network conditions improve, fork choice should
  #                     eventually select the correct head and the rest will
  #                     disappear naturally - risky because user is not aware,
  #                     and might lose stake on canonical chain but "just works"
  #                     when reconnected..
  node.processor[].updateHead(slot)

  # Time passes in here..
  await node.handleValidatorDuties(lastSlot, slot)

  let
    nextSlotStart = saturate(node.beaconClock.fromNow(nextSlot))

  info "Slot end",
    slot = shortLog(slot),
    nextSlot = shortLog(nextSlot),
    head = shortLog(node.chainDag.head),
    headEpoch = shortLog(node.chainDag.head.slot.compute_epoch_at_slot()),
    finalizedHead = shortLog(node.chainDag.finalizedHead.blck),
    finalizedEpoch = shortLog(node.chainDag.finalizedHead.blck.slot.compute_epoch_at_slot())

  # Syncing tends to be ~1 block/s, and allow for an epoch of time for libp2p
  # subscribing to spin up. The faster the sync, the more wallSlot - headSlot
  # lead time is required
  const
    TOPIC_SUBSCRIBE_THRESHOLD_SLOTS = 64
    HYSTERESIS_BUFFER = 16

  let
    syncQueueLen = node.syncManager.syncQueueLen
    topicSubscriptionEnabled = node.getTopicSubscriptionEnabled()
  if
      # Don't enable if already enabled; to avoid race conditions requires care,
      # but isn't crucial, as this condition spuriously fail, but the next time,
      # should properly succeed.
      not topicSubscriptionEnabled and
      # SyncManager forward sync by default runs until maxHeadAge slots, or one
      # epoch range is achieved. This particular condition has a couple caveats
      # including that under certain conditions, debtsCount appears to push len
      # (here, syncQueueLen) to underflow-like values; and even when exactly at
      # the expected walltime slot the queue isn't necessarily empty. Therefore
      # TOPIC_SUBSCRIBE_THRESHOLD_SLOTS is not exactly the number of slots that
      # are left. Furthermore, even when 0 peers are being used, this won't get
      # to 0 slots in syncQueueLen, but that's a vacuous condition given that a
      # networking interaction cannot happen under such circumstances.
      syncQueueLen < TOPIC_SUBSCRIBE_THRESHOLD_SLOTS:
    # When node.cycleAttestationSubnets() is enabled more properly, integrate
    # this into the node.cycleAttestationSubnets() call.
    debug "Enabling topic subscriptions",
      wallSlot = slot,
      headSlot = node.chainDag.head.slot,
      syncQueueLen

    await node.addMessageHandlers()
    doAssert node.getTopicSubscriptionEnabled()
  elif
      topicSubscriptionEnabled and
      syncQueueLen > TOPIC_SUBSCRIBE_THRESHOLD_SLOTS + HYSTERESIS_BUFFER and
      # Filter out underflow from debtsCount; plausible queue lengths can't
      # exceed wallslot, with safety margin.
      syncQueueLen < 2 * slot.uint64:
    debug "Disabling topic subscriptions",
      wallSlot = slot,
      headSlot = node.chainDag.head.slot,
      syncQueueLen
    await node.removeMessageHandlers()

  # Subscription or unsubscription might have occurred; recheck
  if slot.isEpoch and node.getTopicSubscriptionEnabled:
    node.cycleAttestationSubnets(slot)

  when declared(GC_fullCollect):
    # The slots in the beacon node work as frames in a game: we want to make
    # sure that we're ready for the next one and don't get stuck in lengthy
    # garbage collection tasks when time is of essence in the middle of a slot -
    # while this does not guarantee that we'll never collect during a slot, it
    # makes sure that all the scratch space we used during slot tasks (logging,
    # temporary buffers etc) gets recycled for the next slot that is likely to
    # need similar amounts of memory.
    GC_fullCollect()

  addTimer(nextSlotStart) do (p: pointer):
    asyncCheck node.onSlotStart(slot, nextSlot)

proc handleMissingBlocks(node: BeaconNode) =
  let missingBlocks = node.quarantine.checkMissing()
  if missingBlocks.len > 0:
    debug "Requesting detected missing blocks", blocks = shortLog(missingBlocks)
    node.requestManager.fetchAncestorBlocks(missingBlocks)

proc onSecond(node: BeaconNode) =
  ## This procedure will be called once per second.
  if not(node.syncManager.inProgress):
    node.handleMissingBlocks()

proc runOnSecondLoop(node: BeaconNode) {.async.} =
  let sleepTime = chronos.seconds(1)
  const nanosecondsIn1s = float(chronos.seconds(1).nanoseconds)
  while true:
    let start = chronos.now(chronos.Moment)
    await chronos.sleepAsync(sleepTime)
    let afterSleep = chronos.now(chronos.Moment)
    let sleepTime = afterSleep - start
    node.onSecond()
    let finished = chronos.now(chronos.Moment)
    let processingTime = finished - afterSleep
    ticks_delay.set(sleepTime.nanoseconds.float / nanosecondsIn1s)
    trace "onSecond task completed", sleepTime, processingTime

proc startSyncManager(node: BeaconNode) =
  func getLocalHeadSlot(): Slot =
    node.chainDag.head.slot

  proc getLocalWallSlot(): Slot =
    node.beaconClock.now().slotOrZero

  func getFirstSlotAtFinalizedEpoch(): Slot =
    node.chainDag.finalizedHead.slot

  proc scoreCheck(peer: Peer): bool =
    if peer.score < PeerScoreLowLimit:
      false
    else:
      true

  proc onDeletePeer(peer: Peer) =
    if peer.connectionState notin {Disconnecting, Disconnected}:
      if peer.score < PeerScoreLowLimit:
        debug "Peer was removed from PeerPool due to low score", peer = peer,
              peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
              score_high_limit = PeerScoreHighLimit
        asyncSpawn peer.disconnect(PeerScoreLow)
      else:
        debug "Peer was removed from PeerPool", peer = peer,
              peer_score = peer.score, score_low_limit = PeerScoreLowLimit,
              score_high_limit = PeerScoreHighLimit
        asyncSpawn peer.disconnect(FaultOrError)

  node.network.peerPool.setScoreCheck(scoreCheck)
  node.network.peerPool.setOnDeletePeer(onDeletePeer)

  node.syncManager = newSyncManager[Peer, PeerID](
    node.network.peerPool, getLocalHeadSlot, getLocalWallSlot,
    getFirstSlotAtFinalizedEpoch, node.processor.blocksQueue, chunkSize = 32
  )
  node.syncManager.start()

proc connectedPeersCount(node: BeaconNode): int =
  len(node.network.peerPool)

proc installRpcHandlers(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.installBeaconApiHandlers(node)
  rpcServer.installConfigApiHandlers(node)
  rpcServer.installDebugApiHandlers(node)
  rpcServer.installEventApiHandlers(node)
  rpcServer.installNimbusApiHandlers(node)
  rpcServer.installNodeApiHandlers(node)
  rpcServer.installValidatorApiHandlers(node)

proc installMessageValidators(node: BeaconNode) =
  # https://github.com/ethereum/eth2.0-specs/blob/v1.0.0/specs/phase0/p2p-interface.md#attestations-and-aggregation
  # These validators stay around the whole time, regardless of which specific
  # subnets are subscribed to during any given epoch.
  for it in 0'u64 ..< ATTESTATION_SUBNET_COUNT.uint64:
    closureScope:
      let ci = it
      node.network.addValidator(
        getAttestationTopic(node.forkDigest, ci),
        # This proc needs to be within closureScope; don't lift out of loop.
        proc(attestation: Attestation): ValidationResult =
          node.processor[].attestationValidator(attestation, ci))

  node.network.addValidator(
    getAggregateAndProofsTopic(node.forkDigest),
    proc(signedAggregateAndProof: SignedAggregateAndProof): ValidationResult =
      node.processor[].aggregateValidator(signedAggregateAndProof))

  node.network.addValidator(
    node.topicBeaconBlocks,
    proc (signedBlock: SignedBeaconBlock): ValidationResult =
      node.processor[].blockValidator(signedBlock))

  node.network.addValidator(
    getAttesterSlashingsTopic(node.forkDigest),
    proc (attesterSlashing: AttesterSlashing): ValidationResult =
      node.processor[].attesterSlashingValidator(attesterSlashing))

  node.network.addValidator(
    getProposerSlashingsTopic(node.forkDigest),
    proc (proposerSlashing: ProposerSlashing): ValidationResult =
      node.processor[].proposerSlashingValidator(proposerSlashing))

  node.network.addValidator(
    getVoluntaryExitsTopic(node.forkDigest),
    proc (signedVoluntaryExit: SignedVoluntaryExit): ValidationResult =
      node.processor[].voluntaryExitValidator(signedVoluntaryExit))

proc stop*(node: BeaconNode) =
  bnStatus = BeaconNodeStatus.Stopping
  notice "Graceful shutdown"
  if not node.config.inProcessValidators:
    node.vcProcess.close()
  waitFor node.network.stop()
  node.db.close()
  notice "Database closed"

proc run*(node: BeaconNode) =
  if bnStatus == BeaconNodeStatus.Starting:
    # it might have been set to "Stopping" with Ctrl+C
    bnStatus = BeaconNodeStatus.Running

    if node.rpcServer != nil:
      node.rpcServer.installRpcHandlers(node)
      node.rpcServer.start()

    node.installMessageValidators()

    let
      curSlot = node.beaconClock.now().slotOrZero()
      nextSlot = curSlot + 1 # No earlier than GENESIS_SLOT + 1
      fromNow = saturate(node.beaconClock.fromNow(nextSlot))

    info "Scheduling first slot action",
      beaconTime = shortLog(node.beaconClock.now()),
      nextSlot = shortLog(nextSlot),
      fromNow = shortLog(fromNow)

    addTimer(fromNow) do (p: pointer):
      asyncCheck node.onSlotStart(curSlot, nextSlot)

    node.onSecondLoop = runOnSecondLoop(node)
    node.blockProcessingLoop = node.processor.runQueueProcessingLoop()

    node.requestManager.start()
    node.startSyncManager()

  ## Ctrl+C handling
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    notice "Shutting down after having received SIGINT"
    bnStatus = BeaconNodeStatus.Stopping
  setControlCHook(controlCHandler)

  # main event loop
  while bnStatus == BeaconNodeStatus.Running:
    try:
      poll()
    except CatchableError as e:
      debug "Exception in poll()", exc = e.name, err = e.msg

  # time to say goodbye
  node.stop()

var gPidFile: string
proc createPidFile(filename: string) =
  writeFile filename, $os.getCurrentProcessId()
  gPidFile = filename
  addQuitProc proc {.noconv.} = discard io2.removeFile(gPidFile)

proc initializeNetworking(node: BeaconNode) {.async.} =
  await node.network.startListening()

  let addressFile = node.config.dataDir / "beacon_node.enr"
  writeFile(addressFile, node.network.announcedENR.toURI)

  await node.network.start()

  notice "Networking initialized",
    enr = node.network.announcedENR.toURI,
    libp2p = shortLog(node.network.switch.peerInfo)

proc start(node: BeaconNode) =
  let
    head = node.chainDag.head
    finalizedHead = node.chainDag.finalizedHead
    genesisTime = node.beaconClock.fromNow(toBeaconTime(Slot 0))

  notice "Starting beacon node",
    version = fullVersionStr,
    nim = shortNimBanner(),
    timeSinceFinalization =
      finalizedHead.slot.toBeaconTime() -
      node.beaconClock.now(),
    head = shortLog(head),
    finalizedHead = shortLog(finalizedHead),
    SLOTS_PER_EPOCH,
    SECONDS_PER_SLOT,
    SPEC_VERSION,
    dataDir = node.config.dataDir.string

  if genesisTime.inFuture:
    notice "Waiting for genesis", genesisIn = genesisTime.offset

  waitFor node.initializeNetworking()

  if node.eth1Monitor != nil:
    node.eth1Monitor.start()

  node.run()

func formatGwei(amount: uint64): string =
  # TODO This is implemented in a quite a silly way.
  # Better routines for formatting decimal numbers
  # should exists somewhere else.
  let
    eth = amount div 1000000000
    remainder = amount mod 1000000000

  result = $eth
  if remainder != 0:
    result.add '.'
    result.add $remainder
    while result[^1] == '0':
      result.setLen(result.len - 1)

when hasPrompt:
  from unicode import Rune
  import prompt

  func providePromptCompletions*(line: seq[Rune], cursorPos: int): seq[string] =
    # TODO
    # The completions should be generated with the general-purpose command-line
    # parsing API of Confutils
    result = @[]

  proc processPromptCommands(p: ptr Prompt) {.thread.} =
    while true:
      var cmd = p[].readLine()
      case cmd
      of "quit":
        quit 0
      else:
        p[].writeLine("Unknown command: " & cmd)

  proc initPrompt(node: BeaconNode) =
    if isatty(stdout) and node.config.statusBarEnabled:
      enableTrueColors()

      # TODO: nim-prompt seems to have threading issues at the moment
      #       which result in sporadic crashes. We should introduce a
      #       lock that guards the access to the internal prompt line
      #       variable.
      #
      # var p = Prompt.init("nimbus > ", providePromptCompletions)
      # p.useHistoryFile()

      proc dataResolver(expr: string): string =
        template justified: untyped = node.chainDag.head.atEpochStart(
          node.chainDag.headState.data.data.current_justified_checkpoint.epoch)
        # TODO:
        # We should introduce a general API for resolving dot expressions
        # such as `db.latest_block.slot` or `metrics.connected_peers`.
        # Such an API can be shared between the RPC back-end, CLI tools
        # such as ncli, a potential GraphQL back-end and so on.
        # The status bar feature would allow the user to specify an
        # arbitrary expression that is resolvable through this API.
        case expr.toLowerAscii
        of "connected_peers":
          $(node.connectedPeersCount)

        of "head_root":
          shortLog(node.chainDag.head.root)
        of "head_epoch":
          $(node.chainDag.head.slot.epoch)
        of "head_epoch_slot":
          $(node.chainDag.head.slot mod SLOTS_PER_EPOCH)
        of "head_slot":
          $(node.chainDag.head.slot)

        of "justifed_root":
          shortLog(justified.blck.root)
        of "justifed_epoch":
          $(justified.slot.epoch)
        of "justifed_epoch_slot":
          $(justified.slot mod SLOTS_PER_EPOCH)
        of "justifed_slot":
          $(justified.slot)

        of "finalized_root":
          shortLog(node.chainDag.finalizedHead.blck.root)
        of "finalized_epoch":
          $(node.chainDag.finalizedHead.slot.epoch)
        of "finalized_epoch_slot":
          $(node.chainDag.finalizedHead.slot mod SLOTS_PER_EPOCH)
        of "finalized_slot":
          $(node.chainDag.finalizedHead.slot)

        of "epoch":
          $node.currentSlot.epoch

        of "epoch_slot":
          $(node.currentSlot mod SLOTS_PER_EPOCH)

        of "slot":
          $node.currentSlot

        of "slots_per_epoch":
          $SLOTS_PER_EPOCH

        of "slot_trailing_digits":
          var slotStr = $node.currentSlot
          if slotStr.len > 3: slotStr = slotStr[^3..^1]
          slotStr

        of "attached_validators_balance":
          var balance = uint64(0)
          # TODO slow linear scan!
          for idx, b in node.chainDag.headState.data.data.balances:
            if node.getAttachedValidator(
                node.chainDag.headState.data.data, ValidatorIndex(idx)) != nil:
              balance += b
          formatGwei(balance)

        of "sync_status":
          if isNil(node.syncManager):
            "pending"
          else:
            if node.syncManager.inProgress:
              node.syncManager.syncStatus
            else:
              "synced"
        else:
          # We ignore typos for now and just render the expression
          # as it was written. TODO: come up with a good way to show
          # an error message to the user.
          "$" & expr

      var statusBar = StatusBarView.init(
        node.config.statusBarContents,
        dataResolver)

      when compiles(defaultChroniclesStream.output.writer):
        defaultChroniclesStream.output.writer =
          proc (logLevel: LogLevel, msg: LogOutputStr) {.raises: [Defect].} =
            try:
              # p.hidePrompt
              erase statusBar
              # p.writeLine msg
              stdout.write msg
              render statusBar
              # p.showPrompt
            except Exception as e: # render raises Exception
              logLoggingFailure(cstring(msg), e)

      proc statusBarUpdatesPollingLoop() {.async.} =
        while true:
          update statusBar
          await sleepAsync(chronos.seconds(1))

      traceAsyncErrors statusBarUpdatesPollingLoop()

      # var t: Thread[ptr Prompt]
      # createThread(t, processPromptCommands, addr p)

programMain:
  var
    config = makeBannerAndConfig(clientId, BeaconNodeConf)
    # This is ref so we can mutate it (to erase it) after the initial loading.
    genesisStateContents: ref string
    eth1Network: Option[Eth1Network]

  setupStdoutLogging(config.logLevel)

  if not(checkAndCreateDataDir(string(config.dataDir))):
    # We are unable to access/create data folder or data folder's
    # permissions are insecure.
    quit QuitFailure

  setupLogging(config.logLevel, config.logFile)

  ## This Ctrl+C handler exits the program in non-graceful way.
  ## It's responsible for handling Ctrl+C in sub-commands such
  ## as `wallets *` and `deposits *`. In a regular beacon node
  ## run, it will be overwritten later with a different handler
  ## performing a graceful exit.
  proc exitImmediatelyOnCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    echo "" # If we interrupt during an interactive prompt, this
            # will move the cursor to the next line
    notice "Shutting down after having received SIGINT"
    quit 0
  setControlCHook(exitImmediatelyOnCtrlC)

  if config.eth2Network.isSome:
    let metadata = getMetadataForNetwork(config.eth2Network.get)
    config.runtimePreset = metadata.runtimePreset

    if config.cmd == noCommand:
      for node in metadata.bootstrapNodes:
        config.bootstrapNodes.add node

      if metadata.genesisData.len > 0:
        genesisStateContents = newClone metadata.genesisData

    template checkForIncompatibleOption(flagName, fieldName) =
      # TODO: This will have to be reworked slightly when we introduce config files.
      # We'll need to keep track of the "origin" of the config value, so we can
      # discriminate between values from config files that can be overridden and
      # regular command-line options (that may conflict).
      if config.fieldName.isSome:
        fatal "Invalid CLI arguments specified. You must not specify '--network' and '" & flagName & "' at the same time",
            networkParam = config.eth2Network.get, `flagName` = config.fieldName.get
        quit 1

    checkForIncompatibleOption "deposit-contract", depositContractAddress
    checkForIncompatibleOption "deposit-contract-block", depositContractDeployedAt
    config.depositContractAddress = some metadata.depositContractAddress
    config.depositContractDeployedAt = some metadata.depositContractDeployedAt

    eth1Network = metadata.eth1Network
  else:
    config.runtimePreset = defaultRuntimePreset
    when const_preset == "mainnet":
      if config.depositContractAddress.isNone:
        config.depositContractAddress =
          some mainnetMetadata.depositContractAddress
      if config.depositContractDeployedAt.isNone:
        config.depositContractDeployedAt =
          some mainnetMetadata.depositContractDeployedAt
      eth1Network = some mainnet

  # Single RNG instance for the application - will be seeded on construction
  # and avoid using system resources (such as urandom) after that
  let rng = keys.newRng()

  template findWalletWithoutErrors(name: WalletName): auto =
    let res = keystore_management.findWallet(config, name)
    if res.isErr:
      fatal "Failed to locate wallet", error = res.error
      quit 1
    res.get

  case config.cmd
  of createTestnet:
    let launchPadDeposits = try:
      Json.loadFile(config.testnetDepositsFile.string, seq[LaunchPadDeposit])
    except SerializationError as err:
      error "Invalid LaunchPad deposits file",
             err = formatMsg(err, config.testnetDepositsFile.string)
      quit 1

    var deposits: seq[Deposit]
    for i in config.firstValidator.int ..< launchPadDeposits.len:
      deposits.add Deposit(data: launchPadDeposits[i] as DepositData)

    attachMerkleProofs(deposits)

    let
      startTime = uint64(times.toUnix(times.getTime()) + config.genesisOffset)
      outGenesis = config.outputGenesis.string
      eth1Hash = if config.web3Url.len == 0: eth1BlockHash
                 else: (waitFor getEth1BlockHash(config.web3Url, blockId("latest"))).asEth2Digest
    var
      initialState = initialize_beacon_state_from_eth1(
        config.runtimePreset, eth1Hash, startTime, deposits, {skipBlsValidation})

    # https://github.com/ethereum/eth2.0-pm/tree/6e41fcf383ebeb5125938850d8e9b4e9888389b4/interop/mocked_start#create-genesis-state
    initialState.genesis_time = startTime

    doAssert initialState.validators.len > 0

    let outGenesisExt = splitFile(outGenesis).ext
    if cmpIgnoreCase(outGenesisExt, ".json") == 0:
      Json.saveFile(outGenesis, initialState, pretty = true)
      echo "Wrote ", outGenesis

    let outSszGenesis = outGenesis.changeFileExt "ssz"
    SSZ.saveFile(outSszGenesis, initialState[])
    echo "Wrote ", outSszGenesis

    let bootstrapFile = config.outputBootstrapFile.string
    if bootstrapFile.len > 0:
      let
        networkKeys = getPersistentNetKeys(rng[], config)
        netMetadata = getPersistentNetMetadata(config)
        bootstrapEnr = enr.Record.init(
          1, # sequence number
          networkKeys.seckey.asEthKey,
          some(config.bootstrapAddress),
          config.bootstrapPort,
          config.bootstrapPort,
          [toFieldPair("eth2", SSZ.encode(enrForkIdFromState initialState[])),
           toFieldPair("attnets", SSZ.encode(netMetadata.attnets))])

      writeFile(bootstrapFile, bootstrapEnr.tryGet().toURI)
      echo "Wrote ", bootstrapFile

  of noCommand:
    warn "You are running an alpha version of Nimbus - it is not suitable for mainnet!",
      version = fullVersionStr
    info "Launching beacon node",
          version = fullVersionStr,
          bls_backend = $BLS_BACKEND,
          cmdParams = commandLineParams(),
          config

    createPidFile(config.dataDir.string / "beacon_node.pid")

    config.createDumpDirs()

    when useInsecureFeatures:
      if config.metricsEnabled:
        let metricsAddress = config.metricsAddress
        notice "Starting metrics HTTP server",
          address = metricsAddress, port = config.metricsPort
        metrics.startHttpServer($metricsAddress, config.metricsPort)

    # There are no managed event loops in here, to do a graceful shutdown, but
    # letting the default Ctrl+C handler exit is safe, since we only read from
    # the db.
    var node = waitFor BeaconNode.init(
      rng, config, genesisStateContents, eth1Network)

    if bnStatus == BeaconNodeStatus.Stopping:
      return
    # The memory for the initial snapshot won't be needed anymore
    if genesisStateContents != nil: genesisStateContents[] = ""

    when hasPrompt:
      initPrompt(node)

    if node.nickname != "":
      dynamicLogScope(node = node.nickname): node.start()
    else:
      node.start()

  of deposits:
    case config.depositsCmd
    of DepositsCmd.create:
      var seed: KeySeed
      defer: burnMem(seed)
      var walletPath: WalletPathPair

      if config.existingWalletId.isSome:
        let
          id = config.existingWalletId.get
          found = findWalletWithoutErrors(id)

        if found.isSome:
          walletPath = found.get
        else:
          fatal "Unable to find wallet with the specified name/uuid", id
          quit 1

        var unlocked = unlockWalletInteractively(walletPath.wallet)
        if unlocked.isOk:
          swap(seed, unlocked.get)
        else:
          # The failure will be reported in `unlockWalletInteractively`.
          quit 1
      else:
        var walletRes = createWalletInteractively(rng[], config)
        if walletRes.isErr:
          fatal "Unable to create wallet", err = walletRes.error
          quit 1
        else:
          swap(seed, walletRes.get.seed)
          walletPath = walletRes.get.walletPath

      let vres = secureCreatePath(config.outValidatorsDir)
      if vres.isErr():
        fatal "Could not create directory", path = config.outValidatorsDir
        quit QuitFailure

      let sres = secureCreatePath(config.outSecretsDir)
      if sres.isErr():
        fatal "Could not create directory", path = config.outSecretsDir
        quit QuitFailure

      let deposits = generateDeposits(
        config.runtimePreset,
        rng[],
        seed,
        walletPath.wallet.nextAccount,
        config.totalDeposits,
        config.outValidatorsDir,
        config.outSecretsDir)

      if deposits.isErr:
        fatal "Failed to generate deposits", err = deposits.error
        quit 1

      try:
        let depositDataPath = if config.outDepositsFile.isSome:
          config.outDepositsFile.get.string
        else:
          config.outValidatorsDir / "deposit_data-" & $epochTime() & ".json"

        let launchPadDeposits =
          mapIt(deposits.value, LaunchPadDeposit.init(config.runtimePreset, it))

        Json.saveFile(depositDataPath, launchPadDeposits)
        echo "Deposit data written to \"", depositDataPath, "\""

        walletPath.wallet.nextAccount += deposits.value.len
        let status = saveWallet(walletPath)
        if status.isErr:
          fatal "Failed to update wallet file after generating deposits",
                 wallet = walletPath.path,
                 error = status.error
          quit 1
      except CatchableError as err:
        fatal "Failed to create launchpad deposit data file", err = err.msg
        quit 1

    of DepositsCmd.`import`:
      importKeystoresFromDir(
        rng[],
        config.importedDepositsDir.string,
        config.validatorsDir, config.secretsDir)

    of DepositsCmd.status:
      echo "The status command is not implemented yet"
      quit 1

  of wallets:
    case config.walletsCmd:
    of WalletsCmd.create:
      if config.createdWalletNameFlag.isSome:
        let
          name = config.createdWalletNameFlag.get
          existingWallet = findWalletWithoutErrors(name)
        if existingWallet.isSome:
          echo "The Wallet '" & name.string & "' already exists."
          quit 1

      var walletRes = createWalletInteractively(rng[], config)
      if walletRes.isErr:
        fatal "Unable to create wallet", err = walletRes.error
        quit 1
      burnMem(walletRes.get.seed)

    of WalletsCmd.list:
      for kind, walletFile in walkDir(config.walletsDir):
        if kind != pcFile: continue
        if checkSensitiveFilePermissions(walletFile):
          let walletRes = loadWallet(walletFile)
          if walletRes.isOk:
            echo walletRes.get.longName
          else:
            warn "Found corrupt wallet file",
                 wallet = walletFile, error = walletRes.error
        else:
          warn "Found wallet file with insecure permissions",
               wallet = walletFile

    of WalletsCmd.restore:
      restoreWalletInteractively(rng[], config)
