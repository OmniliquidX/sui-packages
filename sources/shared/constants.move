module omniliquid::constants {
    // Precision constants
    public fun price_precision(): u64 { 1_000_000_000 } // 1e9
    public fun size_precision(): u64 { 1_000_000_000 } // 1e9
    public fun bps_precision(): u64 { 10_000 } // 100%
    
    // Trading constants
    public fun max_leverage(): u8 { 100 }
    public fun min_leverage(): u8 { 1 }
    public fun max_position_size(): u64 { 1_000_000 * 1_000_000_000 } // 1M units
    public fun min_position_size(): u64 { 1_000_000 } // 0.001 units
    
    // Risk management
    public fun maintenance_margin_rate(): u64 { 50 } // 0.5% in bps
    public fun liquidation_fee_rate(): u64 { 500 } // 5% in bps
    public fun max_funding_rate(): u64 { 1000 } // 10% in bps
    
    // Vault constants
    public fun vault_lock_period(): u64 { 345_600_000 } // 4 days in ms
    public fun performance_fee(): u64 { 2000 } // 20% in bps
    public fun management_fee(): u64 { 200 } // 2% in bps
    
    // Staking constants
    public fun min_stake_amount(): u64 { 1_000_000_000 } // 1 OMN
    public fun base_apr(): u64 { 1850 } // 18.5% in bps
    public fun max_lock_duration(): u64 { 31_536_000_000 } // 1 year in ms
    
    // Staking multipliers (in bps, 10000 = 1x)
    public fun no_lock_multiplier(): u64 { 10000 } // 1.0x
    public fun week_lock_multiplier(): u64 { 11000 } // 1.1x
    public fun month_lock_multiplier(): u64 { 11500 } // 1.15x
    public fun quarter_lock_multiplier(): u64 { 12000 } // 1.2x
    
    // Time constants
    public fun seconds_per_day(): u64 { 86_400 }
    public fun milliseconds_per_day(): u64 { 86_400_000 }
    public fun week_in_ms(): u64 { 604_800_000 } // 7 days
    public fun month_in_ms(): u64 { 2_592_000_000 } // 30 days
    public fun quarter_in_ms(): u64 { 7_776_000_000 } // 90 days
    
    // Error codes - as functions to make them accessible
    public fun e_invalid_leverage(): u64 { 1001 }
    public fun e_insufficient_collateral(): u64 { 1002 }
    public fun e_position_too_small(): u64 { 1003 }
    public fun e_position_too_large(): u64 { 1004 }
    public fun e_invalid_price(): u64 { 1005 }
    public fun e_market_closed(): u64 { 1006 }
    public fun e_liquidation_threshold(): u64 { 1007 }
    public fun e_vault_locked(): u64 { 1008 }
    public fun e_insufficient_shares(): u64 { 1009 }
    public fun e_stake_too_small(): u64 { 1010 }
    public fun e_stake_locked(): u64 { 1011 }
    public fun e_unauthorized(): u64 { 1012 }
    public fun e_invalid_duration(): u64 { 1013 }
}