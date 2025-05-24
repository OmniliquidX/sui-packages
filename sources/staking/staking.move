module omniliquid::staking {
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use sui::table::{Self, Table};
    use omniliquid::omn::OMN;
    use omniliquid::math;
    use omniliquid::constants;
    use omniliquid::events;

    public struct StakingPool has key {
        id: UID,
        total_staked: u64,
        total_rewards_distributed: u64,
        base_apr_bps: u64,
        admin: address,
        reward_rate_per_ms: u64,
        last_reward_update: u64,
        accumulated_reward_per_token: u64,
        staking_enabled: bool,
    }

    public struct StakePosition has key, store {
        id: UID,
        staker: address,
        amount: u64,
        lock_duration: u64,
        multiplier_bps: u64,
        start_time: u64,
        unlock_time: u64,
        last_reward_claim: u64,
        reward_debt: u64,
    }

    public struct StakeReward has key, store {
        id: UID,
        staker: address,
        amount: u64,
        timestamp: u64,
    }

    public struct AdminCap has key {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        let staking_pool = StakingPool {
            id: object::new(ctx),
            total_staked: 0,
            total_rewards_distributed: 0,
            base_apr_bps: constants::base_apr(),
            admin: tx_context::sender(ctx),
            reward_rate_per_ms: 0,
            last_reward_update: 0,
            accumulated_reward_per_token: 0,
            staking_enabled: true,
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        transfer::share_object(staking_pool);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun stake(
        staking_pool: &mut StakingPool,
        stake_coin: Coin<OMN>,
        lock_duration: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): StakePosition {
        assert!(staking_pool.staking_enabled, constants::e_market_closed());
        
        let stake_amount = coin::value(&stake_coin);
        let timestamp = clock::timestamp_ms(clock);
        let staker = tx_context::sender(ctx);
        
        assert!(stake_amount >= constants::min_stake_amount(), constants::e_stake_too_small());
        assert!(lock_duration <= constants::max_lock_duration(), constants::e_invalid_duration());
        
        // Determine multiplier based on lock duration
        let multiplier_bps = get_lock_multiplier(lock_duration);
        let unlock_time = timestamp + lock_duration;
        
        // Update reward calculations
        update_reward_rate(staking_pool, clock);
        
        // Transfer staked tokens to pool (simplified)
        transfer::public_transfer(stake_coin, @omniliquid);
        
        // Update pool state
        staking_pool.total_staked = staking_pool.total_staked + stake_amount;
        
        // Create stake position
        let stake_position = StakePosition {
            id: object::new(ctx),
            staker,
            amount: stake_amount,
            lock_duration,
            multiplier_bps,
            start_time: timestamp,
            unlock_time,
            last_reward_claim: timestamp,
            reward_debt: 0,
        };
        
        // Emit staking event
        events::emit_tokens_staked(
            staker,
            stake_amount,
            lock_duration,
            multiplier_bps,
            unlock_time,
            timestamp
        );
        
        stake_position
    }

    public entry fun stake_entry(
        staking_pool: &mut StakingPool,
        stake_coin: Coin<OMN>,
        lock_duration: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let stake_position = stake(staking_pool, stake_coin, lock_duration, clock, ctx);
        transfer::transfer(stake_position, tx_context::sender(ctx));
    }

    public fun unstake(
        staking_pool: &mut StakingPool,
        stake_position: StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<OMN>, Coin<SUI>) {
        let timestamp = clock::timestamp_ms(clock);
        let unstaker = tx_context::sender(ctx);
        
        assert!(stake_position.staker == unstaker, constants::e_unauthorized());
        assert!(timestamp >= stake_position.unlock_time, constants::e_stake_locked());
        
        let stake_amount = stake_position.amount;
        
        // Calculate pending rewards
        let pending_rewards = calculate_pending_rewards(&stake_position, staking_pool, clock);
        
        // Update pool state
        staking_pool.total_staked = staking_pool.total_staked - stake_amount;
        staking_pool.total_rewards_distributed = staking_pool.total_rewards_distributed + pending_rewards;
        
        // Emit unstaking event
        events::emit_tokens_unstaked(
            unstaker,
            stake_amount,
            pending_rewards,
            timestamp
        );
        
        // Destroy stake position
        let StakePosition { 
            id, staker: _, amount: _, lock_duration: _, multiplier_bps: _, 
            start_time: _, unlock_time: _, last_reward_claim: _, reward_debt: _ 
        } = stake_position;
        object::delete(id);
        
        // Return staked tokens and rewards (simplified)
        let staked_tokens = coin::mint_balance<OMN>(stake_amount, ctx);
        let reward_tokens = coin::mint_balance<SUI>(pending_rewards, ctx);
        
        (staked_tokens, reward_tokens)
    }

    public entry fun unstake_entry(
        staking_pool: &mut StakingPool,
        stake_position: StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let (staked_tokens, reward_tokens) = unstake(staking_pool, stake_position, clock, ctx);
        let unstaker = tx_context::sender(ctx);
        
        transfer::public_transfer(staked_tokens, unstaker);
        transfer::public_transfer(reward_tokens, unstaker);
    }

    public fun claim_rewards(
        staking_pool: &mut StakingPool,
        stake_position: &mut StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let timestamp = clock::timestamp_ms(clock);
        let claimer = tx_context::sender(ctx);
        
        assert!(stake_position.staker == claimer, constants::e_unauthorized());
        
        let pending_rewards = calculate_pending_rewards(stake_position, staking_pool, clock);
        assert!(pending_rewards > 0, constants::e_insufficient_collateral());
        
        // Update stake position
        stake_position.last_reward_claim = timestamp;
        stake_position.reward_debt = stake_position.reward_debt + pending_rewards;
        
        // Update pool state
        staking_pool.total_rewards_distributed = staking_pool.total_rewards_distributed + pending_rewards;
        
        // Emit rewards claimed event
        events::emit_rewards_claimed(
            claimer,
            pending_rewards,
            timestamp
        );
        
        // Return reward tokens (simplified)
        coin::mint_balance<SUI>(pending_rewards, ctx)
    }

    public entry fun claim_rewards_entry(
        staking_pool: &mut StakingPool,
        stake_position: &mut StakePosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let reward_tokens = claim_rewards(staking_pool, stake_position, clock, ctx);
        transfer::public_transfer(reward_tokens, tx_context::sender(ctx));
    }

    public fun calculate_pending_rewards(
        stake_position: &StakePosition,
        staking_pool: &StakingPool,
        clock: &Clock
    ): u64 {
        let current_time = clock::timestamp_ms(clock);
        let time_elapsed = current_time - stake_position.last_reward_claim;
        
        if (time_elapsed == 0) {
            return 0
        };
        
        // Calculate base rewards
        let base_rewards = math::calculate_staking_rewards(
            stake_position.amount,
            staking_pool.base_apr_bps,
            constants::bps_precision(), // No multiplier for base calculation
            time_elapsed
        );
        
        // Apply lock multiplier
        let boosted_rewards = math::mul_div(
            base_rewards,
            stake_position.multiplier_bps,
            constants::bps_precision()
        );
        
        boosted_rewards
    }

    fun get_lock_multiplier(lock_duration: u64): u64 {
        if (lock_duration == 0) {
            constants::no_lock_multiplier()
        } else if (lock_duration <= constants::week_in_ms()) {
            constants::week_lock_multiplier()
        } else if (lock_duration <= constants::month_in_ms()) {
            constants::month_lock_multiplier()
        } else if (lock_duration <= constants::quarter_in_ms()) {
            constants::quarter_lock_multiplier()
        } else {
            constants::quarter_lock_multiplier() // Max multiplier for longer locks
        }
    }

    fun update_reward_rate(
        staking_pool: &mut StakingPool,
        clock: &Clock
    ) {
        let timestamp = clock::timestamp_ms(clock);
        
        if (staking_pool.total_staked > 0) {
            // Calculate reward rate per millisecond
            let annual_rewards = math::mul_div(
                staking_pool.total_staked,
                staking_pool.base_apr_bps,
                constants::bps_precision()
            );
            
            staking_pool.reward_rate_per_ms = annual_rewards / (365 * constants::milliseconds_per_day());
        } else {
            staking_pool.reward_rate_per_ms = 0;
        };
        
        staking_pool.last_reward_update = timestamp;
    }

    // Admin functions
    public fun set_base_apr(
        staking_pool: &mut StakingPool,
        _admin_cap: &AdminCap,
        new_apr_bps: u64,
        clock: &Clock
    ) {
        assert!(new_apr_bps <= 10000, constants::e_invalid_price()); // Max 100% APR
        
        update_reward_rate(staking_pool, clock);
        staking_pool.base_apr_bps = new_apr_bps;
    }

    public fun enable_staking(
        staking_pool: &mut StakingPool,
        _admin_cap: &AdminCap,
    ) {
        staking_pool.staking_enabled = true;
    }

    public fun disable_staking(
        staking_pool: &mut StakingPool,
        _admin_cap: &AdminCap,
    ) {
        staking_pool.staking_enabled = false;
    }

    public fun emergency_unstake(
        staking_pool: &mut StakingPool,
        _admin_cap: &AdminCap,
        stake_position: StakePosition,
        ctx: &mut TxContext
    ): Coin<OMN> {
        let stake_amount = stake_position.amount;
        
        // Update pool state
        staking_pool.total_staked = staking_pool.total_staked - stake_amount;
        
        // Destroy stake position without rewards
        let StakePosition { 
            id, staker: _, amount: _, lock_duration: _, multiplier_bps: _, 
            start_time: _, unlock_time: _, last_reward_claim: _, reward_debt: _ 
        } = stake_position;
        object::delete(id);
        
        // Return staked tokens only (no rewards)
        coin::mint_balance<OMN>(stake_amount, ctx)
    }

    // View functions
    public fun total_staked(staking_pool: &StakingPool): u64 {
        staking_pool.total_staked
    }

    public fun base_apr_bps(staking_pool: &StakingPool): u64 {
        staking_pool.base_apr_bps
    }

    public fun total_rewards_distributed(staking_pool: &StakingPool): u64 {
        staking_pool.total_rewards_distributed
    }

    public fun staking_enabled(staking_pool: &StakingPool): bool {
        staking_pool.staking_enabled
    }

    public fun stake_amount(stake_position: &StakePosition): u64 {
        stake_position.amount
    }

    public fun stake_lock_duration(stake_position: &StakePosition): u64 {
        stake_position.lock_duration
    }

    public fun stake_multiplier_bps(stake_position: &StakePosition): u64 {
        stake_position.multiplier_bps
    }

    public fun stake_start_time(stake_position: &StakePosition): u64 {
        stake_position.start_time
    }

    public fun stake_unlock_time(stake_position: &StakePosition): u64 {
        stake_position.unlock_time
    }

    public fun stake_staker(stake_position: &StakePosition): address {
        stake_position.staker
    }

    public fun is_stake_unlocked(stake_position: &StakePosition, clock: &Clock): bool {
        let current_time = clock::timestamp_ms(clock);
        current_time >= stake_position.unlock_time
    }

    public fun time_until_unlock(stake_position: &StakePosition, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        if (current_time >= stake_position.unlock_time) {
            0
        } else {
            stake_position.unlock_time - current_time
        }
    }

    // Helper function to get staking tiers for frontend
    public fun get_staking_tiers(): (vector<u64>, vector<u64>, vector<String>) {
        let durations = vector[
            0,
            constants::week_in_ms(),
            constants::month_in_ms(),
            constants::quarter_in_ms()
        ];
        
        let multipliers = vector[
            constants::no_lock_multiplier(),
            constants::week_lock_multiplier(),
            constants::month_lock_multiplier(),
            constants::quarter_lock_multiplier()
        ];
        
        let names = vector[
            std::string::utf8(b"No Lock"),
            std::string::utf8(b"1 Week"),
            std::string::utf8(b"1 Month"),
            std::string::utf8(b"3 Months")
        ];
        
        (durations, multipliers, names)
    }
}