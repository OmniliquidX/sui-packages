module omniliquid::omn {
    use std::option;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url;

    public struct OMN has drop {}

    fun init(witness: OMN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<OMN>(
            witness,
            9, // Decimals
            b"OMN",
            b"Omniliquid Token",
            b"Governance and utility token for the Omniliquid protocol",
            option::some(url::new_unsafe_from_bytes(b"https://sui.omniliquid.xyz/logo.png")),
            ctx
        );

        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    public entry fun mint(
        treasury_cap: &mut TreasuryCap<OMN>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        coin::mint_and_transfer(treasury_cap, amount, recipient, ctx);
    }

    public fun burn(
        treasury_cap: &mut TreasuryCap<OMN>,
        coin: Coin<OMN>
    ): u64 {
        coin::burn(treasury_cap, coin)
    }

    // Utility functions for other modules
    public fun split_coin(
        coin: &mut Coin<OMN>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<OMN> {
        coin::split(coin, amount, ctx)
    }

    public fun join_coins(
        coin1: &mut Coin<OMN>,
        coin2: Coin<OMN>
    ) {
        coin::join(coin1, coin2);
    }

    public fun value(coin: &Coin<OMN>): u64 {
        coin::value(coin)
    }

    public fun zero(ctx: &mut TxContext): Coin<OMN> {
        coin::zero<OMN>(ctx)
    }

    public fun destroy_zero(coin: Coin<OMN>) {
        coin::destroy_zero(coin);
    }
}