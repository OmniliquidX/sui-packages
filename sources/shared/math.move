module omniliquid::math {
    use omniliquid::constants;

    public fun mul_div(a: u64, b: u64, c: u64): u64 {
        ((a as u128) * (b as u128) / (c as u128) as u64)
    }

    public fun calculate_pnl(
        entry_price: u64,
        current_price: u64,
        size: u64,
        is_long: bool
    ): (bool, u64) {
        if (is_long) {
            if (current_price >= entry_price) {
                let profit = mul_div(
                    current_price - entry_price,
                    size,
                    constants::price_precision()
                );
                (true, profit)
            } else {
                let loss = mul_div(
                    entry_price - current_price,
                    size,
                    constants::price_precision()
                );
                (false, loss)
            }
        } else {
            if (entry_price >= current_price) {
                let profit = mul_div(
                    entry_price - current_price,
                    size,
                    constants::price_precision()
                );
                (true, profit)
            } else {
                let loss = mul_div(
                    current_price - entry_price,
                    size,
                    constants::price_precision()
                );
                (false, loss)
            }
        }
    }

    public fun calculate_liquidation_price(
        entry_price: u64,
        leverage: u8,
        is_long: bool
    ): u64 {
        let maintenance_rate = constants::maintenance_margin_rate();
        let max_loss_bps = constants::bps_precision() / (leverage as u64) - maintenance_rate;
        
        if (is_long) {
            entry_price - mul_div(entry_price, max_loss_bps, constants::bps_precision())
        } else {
            entry_price + mul_div(entry_price, max_loss_bps, constants::bps_precision())
        }
    }

    public fun calculate_required_collateral(
        size: u64,
        price: u64,
        leverage: u8
    ): u64 {
        mul_div(size, price, (leverage as u64) * constants::price_precision())
    }

    public fun calculate_funding_payment(
        position_size: u64,
        funding_rate: u64,
        time_elapsed: u64
    ): u64 {
        let daily_rate = mul_div(funding_rate, time_elapsed, constants::milliseconds_per_day());
        mul_div(position_size, daily_rate, constants::bps_precision())
    }

    public fun calculate_staking_rewards(
        staked_amount: u64,
        apr_bps: u64,
        multiplier_bps: u64,
        time_elapsed_ms: u64
    ): u64 {
        let annual_reward = mul_div(staked_amount, apr_bps, constants::bps_precision());
        let boosted_reward = mul_div(annual_reward, multiplier_bps, constants::bps_precision());
        mul_div(boosted_reward, time_elapsed_ms, 365 * constants::milliseconds_per_day())
    }

    public fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    public fun max(a: u64, b: u64): u64 {
        if (a > b) a else b
    }

    public fun abs_diff(a: u64, b: u64): u64 {
        if (a >= b) {
            a - b
        } else {
            b - a
        }
    }

    public fun is_within_threshold(
        current: u64,
        target: u64,
        threshold_bps: u64
    ): bool {
        let diff = abs_diff(current, target);
        let max_diff = mul_div(target, threshold_bps, constants::bps_precision());
        diff <= max_diff
    }
}