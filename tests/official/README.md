Note on serialization hacks:

### FAR_FUTURE_SLOT (18446744073709551615)

The FAR_FUTURE_SLOT (18446744073709551615) has been rewritten as a string **in the YAML file**
as it's 2^64-1 and Nim by default try to parse it into a int64 (which can represents up to 2^63-1).

The YAML file is then converted to JSON for easy input to the json serialization/deserialization
with beacon chain type support.

"18446744073709551615" is then replaced again by uint64 18446744073709551615.

### Compressed signature

In `latest_block_header` field, the signatures and randao_reveals are
`"0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"`
but that is not a valid compressed BLS signature, the zero signature should be:
`"0xc00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"`