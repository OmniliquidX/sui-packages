module omniliquid::collateral {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::balance::{Self, Balance};
    use omniliquid::events;

    public struct UserCollateral has key, store {
        id: UID,
        owner: address,
        balance: Balance<SUI>,
        available_amount: u64,
        last_update: u64,
    }

    public fun create_and_deposit(
        deposit_coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    module omniliquid::collateral {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use omniliquid::events;

    public struct UserCollateral has key, store {
        id: UID,
        owner: address,
        total_amount: u64,
        available_amount: u64,
        last_update: u64,
    }

    ): UserCollateral {
        let amount = coin::value(&deposit_coin);
        let sender = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);
        
        let balance = coin::into_balance(deposit_coin);

        events::emit_collateral_deposited(sender, amount, amount, timestamp);

        UserCollateral {
            id: object::new(ctx),
            owner: sender,
            balance,
            available_amount: amount,
            last_update: timestamp,
        }
    }

    public entry fun create_and_deposit_entry(
        deposit_coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let collateral = create_and_deposit(deposit_coin, clock, ctx);
        transfer::transfer(collateral, tx_context::sender(ctx));
    }

    public fun deposit(
        collateral: &mut UserCollateral,
        deposit_coin: Coin<SUI>,
        clock: &Clock,
    ) {
        let amount = coin::value(&deposit_coin);
        let timestamp = clock::timestamp_ms(clock);
        
        balance::join(&mut collateral.balance, coin::into_balance(deposit_coin));
        
        collateral.available_amount = collateral.available_amount + amount;
        collateral.last_update = timestamp;

        events::emit_collateral_deposited(
            collateral.owner, 
            amount, 
            balance::value(&collateral.balance), 
            timestamp
        );
    }

    public entry fun deposit_entry(
        collateral: &mut UserCollateral,
        deposit_coin: Coin<SUI>,
        clock: &Clock,
    ) {
        deposit(collateral, deposit_coin, clock);
    }

    public fun withdraw(
        collateral: &mut UserCollateral,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(amount <= collateral.available_amount, 0);
        
        let timestamp = clock::timestamp_ms(clock);
        
        collateral.available_amount = collateral.available_amount - amount;
        collateral.last_update = timestamp;

        let withdrawn_balance = balance::split(&mut collateral.balance, amount);
        let total_amount = balance::value(&collateral.balance);

        events::emit_collateral_withdrawn(
            collateral.owner,
            amount,
            total_amount,
            timestamp
        );

        coin::from_balance(withdrawn_balance, ctx)
    }

    public entry fun withdraw_entry(
        collateral: &mut UserCollateral,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let withdrawn_coin = withdraw(collateral, amount, clock, ctx);
        transfer::public_transfer(withdrawn_coin, tx_context::sender(ctx));
    }

    public fun reserve_collateral(
        collateral: &mut UserCollateral,
        amount: u64
    ) {
        assert!(amount <= collateral.available_amount, 0);
        collateral.available_amount = collateral.available_amount - amount;
    }

    public fun release_collateral(
        collateral: &mut UserCollateral,
        amount: u64
    ) {
        collateral.available_amount = collateral.available_amount + amount;
    }

    public fun remove_collateral(
        collateral: &mut UserCollateral,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let total_amount = balance::value(&collateral.balance);
        assert!(amount <= total_amount, 0);
        
        // Adjust available amount if needed
        if (amount > (total_amount - collateral.available_amount)) {
            let excess = amount - (total_amount - collateral.available_amount);
            if (excess <= collateral.available_amount) {
                collateral.available_amount = collateral.available_amount - excess;
            } else {
                collateral.available_amount = 0;
            }
        };

        let removed_balance = balance::split(&mut collateral.balance, amount);
        coin::from_balance(removed_balance, ctx)
    }

    // View functions
    public fun total_amount(collateral: &UserCollateral): u64 {
        balance::value(&collateral.balance)
    }

    public fun available_amount(collateral: &UserCollateral): u64 {
        collateral.available_amount
    }

    public fun owner(collateral: &UserCollateral): address {
        collateral.owner
    }

    public fun last_update(collateral: &UserCollateral): u64 {
        collateral.last_update
    }

    public fun reserved_amount(collateral: &UserCollateral): u64 {
        balance::value(&collateral.balance) - collateral.available_amount
    }
}
