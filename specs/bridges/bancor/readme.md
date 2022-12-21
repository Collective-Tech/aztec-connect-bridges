# Spec for Bancor V3 Aztec Bridge

## What does the bridge do? Why build it?

The bridge swaps `_inputAssetA` for `_outputAssetA` using the Bancor V3 tradeBySourceAmount() function

## What protocol(s) does the bridge interact with ?

The bridge interacts with [Bancor v3](https://docs.bancor.network/about-bancor-network/bancor-v3).

## What is the flow of the bridge?

There is only 1 flow in the bridge.
In this flow `_inputAssetA` is swapped for `_outputAssetA`

**Edge cases**:

- Interaction might revert in case the minimum acceptable price is set too high or the price of the output asset moves up before the interaction settles.
- Users might get sandwiched in case the minimum acceptable price is set too low or the price of the output token goes down before the interaction settles making the users lose positive slippage.

### General Properties of convert(...) function

- The bridge is synchronous, and will always return `isAsync = false`.

- The bridge uses `_auxData` to encode minReturnAmount as a whole number in tokens.
  Details on the encoding are in the bridge's NatSpec documentation.

- The Bridge perform token pre-approvals to allow the `ROLLUP_PROCESSOR` and `UNI_ROUTER` to pull tokens from it.
  This is to reduce gas-overhead when performing the actions. It is safe to do, as the bridge is not holding the funds itself.

## Is the contract upgradeable?

No, the bridge is immutable without any admin role.

## Does the bridge maintain state?

No, the bridge doesn't maintain a state.
