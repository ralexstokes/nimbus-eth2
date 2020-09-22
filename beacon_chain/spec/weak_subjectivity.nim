import
  datatypes

proc compute_weak_subjectivity_period*(state: BeaconState): uint64 =
  var weak_subjectivity_period = MIN_VALIDATOR_WITHDRAWABILITY_DELAY
  let validator_count = get_active_validator_indices_len(state, get_current_epoch(state))
  if validator_count >= MIN_PER_EPOCH_CHURN_LIMIT * CHURN_LIMIT_QUOTIENT:
      weak_subjectivity_period += SAFETY_DECAY * CHURN_LIMIT_QUOTIENT / (2 * 100)
  else:
      weak_subjectivity_period += SAFETY_DECAY * validator_count / (2 * 100 * MIN_PER_EPOCH_CHURN_LIMIT)
  return weak_subjectivity_period
