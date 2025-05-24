module omniliquid::vault {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use sui::table::{Self, Table};
    use omniliquid::math;
    use omniliquid::constants;
    use omniliquid::events;

    public struct VaultState has key {
        id: UID,
        total_deposits: u64,
        total_shares: u64,
        share_price: u64,
        performance_fee_bps: u64,
        management_fee_bps: u64,
        lock_period_ms: u64,
        admin: address,
        total_pnl: u64,
        is_profit: bool,
        last_performance_update: u64,
        trading_enabled: bool,
    }

    public struct VaultShare has key, store {
        id: UID,
        owner: address,
        shares: u64,
        deposit_amount: u64,
        deposit_time: u64,
        lock_until: u64,
    }

    public struct AdminCap has key {
        id: UID,
    }

    public struct PerformanceRecord has store {
        timestamp: u64,
        total_value: u64,
        share_price: u64,
        pnl: u64,
        is_profit: bool,
    }

    fun init(ctx: &mut TxContext) {
        let vault_state = VaultState {
            id: object::new(ctx),
            total_deposits: 0,
            total_shares: 0,
            share_price: constants::PRICE_PRECISION(), // Initial price = 1.0
            performance_fee_bps: constants::PERFORMANCE_FEE(),
            management_fee_bps: constants::MANAGEMENT_FEE(),
            lock_period_ms: constants::VAULT_LOCK_PERIOD(),
            admin: tx_context::sender(ctx),
            total_pnl: 0,
            is_profit: true,
            last_performance_update: 0,
            trading_enabled: true,
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        transfer::share_object(vault_state);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun deposit(
        vault_state: &mut VaultState,
        deposit_coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ): VaultShare {
        let deposit_amount = coin::value(&deposit_coin);
        let timestamp = clock::timestamp_ms(clock);
        let depositor = tx_context::sender(ctx);
        
        assert!(deposit_amount > 0, constants::e_insufficient_collateral());
        
        // Calculate shares to mint
        let shares_to_mint = if (vault_state.total_shares == 0) {
            deposit_amount
        } else {
            math::mul_div(deposit_amount, vault_state.total_shares, vault_state.total_deposits)
        };
        
        // Update vault state
        vault_state.total_deposits = vault_state.total_deposits + deposit_amount;
        vault_state.total_shares = vault_state.total_shares + shares_to_mint;
        
        // Calculate lock time
        let lock_until = timestamp + vault_state.lock_period_ms;
        
        // Transfer deposit to vault (simplified - in production would manage treasury)
        transfer::public_transfer(deposit_coin, @omniliquid);
        
        // Create vault share NFT
        let vault_share = VaultShare {
            id: object::new(ctx),
            owner: depositor,
            shares: shares_to_mint,
            deposit_amount,
            deposit_time: timestamp,
            lock_until,
        };
        
        // Emit event
        events::emit_vault_deposit(
            depositor,
            deposit_amount,
            shares_to_mint,
            vault_state.share_price,
            timestamp
        );
        
        vault_share
    }

    public entry fun deposit_entry(
        vault_state: &mut VaultState,
        deposit_coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let vault_share = deposit(vault_state, deposit_coin, clock, ctx);
        transfer::transfer(vault_share, tx_context::sender(ctx));
    }

    public fun withdraw(
        vault_state: &mut VaultState,
        vault_share: VaultShare,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let timestamp = clock::timestamp_ms(clock);
        let withdrawer = tx_context::sender(ctx);
        
        assert!(vault_share.owner == withdrawer, constants::e_unauthorized());
        assert!(timestamp >= vault_share.lock_until, constants::e_vault_locked());
        
        let shares_to_burn = vault_share.shares;
        
        // Calculate withdrawal amount based on current share price
        let withdrawal_amount = math::mul_div(
            shares_to_burn,
            vault_state.total_deposits,
            vault_state.total_shares
        );
        
        // Apply management fee if applicable
        let time_held = timestamp - vault_share.deposit_time;
        let annual_fee = math::mul_div(
            withdrawal_amount,
            vault_state.management_fee_bps,
            constants::bps_precision()
        );
        let management_fee = math::mul_div(
            annual_fee,
            time_held,
            365 * constants::milliseconds_per_day()
        );
        
        let final_amount = if (management_fee >= withdrawal_amount) {
            0
        } else {
            withdrawal_amount - management_fee
        };
        
        // Update vault state
        vault_state.total_deposits = vault_state.total_deposits - withdrawal_amount;
        vault_state.total_shares = vault_state.total_shares - shares_to_burn;
        
        // Emit event
        events::emit_vault_withdraw(
            withdrawer,
            shares_to_burn,
            final_amount,
            vault_state.share_price,
            timestamp
        );
        
        // Destroy vault share
        let VaultShare { 
            id, owner: _, shares: _, deposit_amount: _, 
            deposit_time: _, lock_until: _ 
        } = vault_share;
        object::delete(id);
        
        // Return withdrawal amount (simplified)
        coin::mint_balance(final_amount, ctx)
    }

    public entry fun withdraw_entry(
        vault_state: &mut VaultState,
        vault_share: VaultShare,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let withdrawn_coin = withdraw(vault_state, vault_share, clock, ctx);
        transfer::public_transfer(withdrawn_coin, tx_context::sender(ctx));
    }

    public fun update_performance(
        vault_state: &mut VaultState,
        _admin_cap: &AdminCap,
        new_total_value: u64,
        clock: &Clock,
    ) {
        let timestamp = clock::timestamp_ms(clock);
        
        // Calculate PnL
        let previous_value = vault_state.total_deposits;
        let (is_profit, pnl_amount) = if (new_total_value >= previous_value) {
            (true, new_total_value - previous_value)
        } else {
            (false, previous_value - new_total_value)
        };
        
        // Update share price
        if (vault_state.total_shares > 0) {
            vault_state.share_price = math::mul_div(
                new_total_value,
                constants::price_precision(),
                vault_state.total_shares
            );
        };
        
        // Calculate and collect performance fee
        if (is_profit && pnl_amount > 0) {
            let performance_fee = math::mul_div(
                pnl_amount,
                vault_state.performance_fee_bps,
                constants::bps_precision()
            );
            
            // Reduce total value by performance fee
            let net_value = new_total_value - performance_fee;
            vault_state.total_deposits = net_value;
            
            // Update share price after fee
            if (vault_state.total_shares > 0) {
                vault_state.share_price = math::mul_div(
                    net_value,
                    constants::price_precision(),
                    vault_state.total_shares
                );
            };
        } else {
            vault_state.total_deposits = new_total_value;
        };
        
        vault_state.total_pnl = pnl_amount;
        vault_state.is_profit = is_profit;
        vault_state.last_performance_update = timestamp;
        
        // Emit performance update event
        events::emit_performance_update(
            vault_state.total_deposits,
            vault_state.share_price,
            if (is_profit && pnl_amount > 0) {
                math::mul_div(pnl_amount, vault_state.performance_fee_bps, constants::bps_precision())
            } else {
                0
            },
            timestamp
        );
    }

    public fun set_lock_period(
        vault_state: &mut VaultState,
        _admin_cap: &AdminCap,
        new_lock_period_ms: u64,
    ) {
        vault_state.lock_period_ms = new_lock_period_ms;
    }

    public fun set_fees(
        vault_state: &mut VaultState,
        _admin_cap: &AdminCap,
        performance_fee_bps: u64,
        management_fee_bps: u64,
    ) {
        assert!(performance_fee_bps <= 5000, constants::e_invalid_price()); // Max 50%
        assert!(management_fee_bps <= 1000, constants::e_invalid_price());  // Max 10%
        
        vault_state.performance_fee_bps = performance_fee_bps;
        vault_state.management_fee_bps = management_fee_bps;
    }

    public fun enable_trading(
        vault_state: &mut VaultState,
        _admin_cap: &AdminCap,
    ) {
        vault_state.trading_enabled = true;
    }

    public fun disable_trading(
        vault_state: &mut VaultState,
        _admin_cap: &AdminCap,
    ) {
        vault_state.trading_enabled = false;
    }

    // View functions
    public fun total_value_locked(vault_state: &VaultState): u64 {
        vault_state.total_deposits
    }

    public fun total_shares(vault_state: &VaultState): u64 {
        vault_state.total_shares
    }

    public fun share_price(vault_state: &VaultState): u64 {
        vault_state.share_price
    }

    public fun get_user_value(vault_share: &VaultShare, vault_state: &VaultState): u64 {
        if (vault_state.total_shares == 0) {
            return 0
        };
        
        math::mul_div(
            vault_share.shares,
            vault_state.total_deposits,
            vault_state.total_shares
        )
    }

    public fun is_unlocked(vault_share: &VaultShare, clock: &Clock): bool {
        let current_time = clock::timestamp_ms(clock);
        current_time >= vault_share.lock_until
    }

    public fun time_until_unlock(vault_share: &VaultShare, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        if (current_time >= vault_share.lock_until) {
            0
        } else {
            vault_share.lock_until - current_time
        }
    }

    public fun vault_share_owner(vault_share: &VaultShare): address {
        vault_share.owner
    }

    public fun vault_share_shares(vault_share: &VaultShare): u64 {
        vault_share.shares
    }

    public fun vault_share_deposit_amount(vault_share: &VaultShare): u64 {
        vault_share.deposit_amount
    }

    public fun vault_share_deposit_time(vault_share: &VaultShare): u64 {
        vault_share.deposit_time
    }

    public fun vault_share_lock_until(vault_share: &VaultShare): u64 {
        vault_share.lock_until
    }

    public fun performance_fee_bps(vault_state: &VaultState): u64 {
        vault_state.performance_fee_bps
    }

    public fun management_fee_bps(vault_state: &VaultState): u64 {
        vault_state.management_fee_bps
    }

    public fun lock_period_ms(vault_state: &VaultState): u64 {
        vault_state.lock_period_ms
    }

    public fun last_performance_update(vault_state: &VaultState): u64 {
        vault_state.last_performance_update
    }

    public fun trading_enabled(vault_state: &VaultState): bool {
        vault_state.trading_enabled
    }

    public fun total_pnl(vault_state: &VaultState): (bool, u64) {
        (vault_state.is_profit, vault_state.total_pnl)
    }
}