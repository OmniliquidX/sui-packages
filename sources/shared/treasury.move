module omniliquid::treasury {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::balance::{Self, Balance};

    // Treasury for managing protocol funds
    public struct ProtocolTreasury has key {
        id: UID,
        balance: Balance<SUI>,
        admin: address,
    }

    public struct AdminCap has key {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        let treasury = ProtocolTreasury {
            id: object::new(ctx),
            balance: balance::zero<SUI>(),
            admin: tx_context::sender(ctx),
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        transfer::share_object(treasury);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // Deposit funds to treasury
    public fun deposit(
        treasury: &mut ProtocolTreasury,
        coin: Coin<SUI>,
    ) {
        balance::join(&mut treasury.balance, coin::into_balance(coin));
    }

    // Withdraw funds from treasury (admin only)
    public fun withdraw(
        treasury: &mut ProtocolTreasury,
        _admin_cap: &AdminCap,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(amount <= balance::value(&treasury.balance), 0);
        let withdrawn_balance = balance::split(&mut treasury.balance, amount);
        coin::from_balance(withdrawn_balance, ctx)
    }

    // Create coins for trading payouts
    public fun create_coin(
        treasury: &mut ProtocolTreasury,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        // In a real implementation, this would be backed by actual reserves
        // For now, we'll ensure we have sufficient balance
        if (balance::value(&treasury.balance) >= amount) {
            let coin_balance = balance::split(&mut treasury.balance, amount);
            coin::from_balance(coin_balance, ctx)
        } else {
            // If insufficient funds, create zero coin (shouldn't happen in production)
            coin::zero<SUI>(ctx)
        }
    }

    // Get treasury balance
    public fun balance_value(treasury: &ProtocolTreasury): u64 {
        balance::value(&treasury.balance)
    }

    // Fund treasury with initial liquidity (admin only)
    public fun fund_treasury(
        treasury: &mut ProtocolTreasury,
        _admin_cap: &AdminCap,
        funding_coin: Coin<SUI>,
    ) {
        deposit(treasury, funding_coin);
    }
}