module omniliquid::price_oracle {
    use std::string::String;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::price_identifier;
    use pyth::price;
    use pyth::pyth;
    use omniliquid::constants;

    public struct PriceOracle has key {
        id: UID,
        prices: Table<String, PriceConfig>,
        admin: address,
    }

    public struct PriceConfig has store, drop {
        pyth_price_id: vector<u8>,
        max_age_seconds: u64,
        is_active: bool,
        fallback_price: u64,
        last_update: u64,
    }

    public struct AdminCap has key {
        id: UID,
    }

    // Pyth price feed IDs for major assets (without 0x prefix)
    // Complete list at: https://pyth.network/developers/price-feed-ids
    const BTC_USD_PRICE_ID: vector<u8> = x"e62df6c8b4c85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";
    const ETH_USD_PRICE_ID: vector<u8> = x"ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";
    const SOL_USD_PRICE_ID: vector<u8> = x"ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";
    const SUI_USD_PRICE_ID: vector<u8> = x"23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744";

    fun init(ctx: &mut TxContext) {
        let oracle = PriceOracle {
            id: object::new(ctx),
            prices: table::new(ctx),
            admin: tx_context::sender(ctx),
        };
        
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        transfer::share_object(oracle);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun add_price_feed(
        oracle: &mut PriceOracle,
        _admin_cap: &AdminCap,
        symbol: String,
        pyth_price_id: vector<u8>,
        max_age_seconds: u64,
    ) {
        let price_config = PriceConfig {
            pyth_price_id,
            max_age_seconds,
            is_active: true,
            fallback_price: 0,
            last_update: 0,
        };
        
        if (table::contains(&oracle.prices, symbol)) {
            let existing = table::borrow_mut(&mut oracle.prices, symbol);
            *existing = price_config;
        } else {
            table::add(&mut oracle.prices, symbol, price_config);
        }
    }

    public fun get_price_from_pyth(
        oracle: &PriceOracle,
        symbol: String,
        price_info_object: &PriceInfoObject,
        clock: &Clock,
    ): (u64, u64) {
        assert!(table::contains(&oracle.prices, symbol), constants::e_invalid_price());
        
        let price_config = table::borrow(&oracle.prices, symbol);
        assert!(price_config.is_active, constants::e_market_closed());
        
        // Verify the price feed ID matches expected
        let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
        let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
        assert!(price_id == price_config.pyth_price_id, constants::e_invalid_price());
        
        // Get price with maximum age check
        let price_struct = pyth::get_price_no_older_than(
            price_info_object, 
            clock, 
            price_config.max_age_seconds
        );
        
        // Extract price data
        let price_i64 = price::get_price(&price_struct);
        let expo_i64 = price::get_expo(&price_struct);
        let confidence_i64 = price::get_conf(&price_struct);
        
        // Convert to u64 with proper scaling
        // Pyth prices come with negative exponents (e.g., -8 for 8 decimals)
        let price_u64 = if (price_i64 >= 0) {
            (price_i64 as u64)
        } else {
            0 // Handle negative prices as zero
        };
        
        let confidence_u64 = (confidence_i64 as u64);
        
        // Scale price to our precision (1e9)
        let scaled_price = if (expo_i64 < 0) {
            let scale_factor = pow_10((-expo_i64 as u8));
            price_u64 * constants::price_precision() / scale_factor
        } else {
            price_u64 * constants::price_precision() * pow_10((expo_i64 as u8))
        };
        
        (scaled_price, confidence_u64)
    }

    // Fallback function for when Pyth is unavailable
    public fun get_price_with_fallback(
        oracle: &PriceOracle,
        symbol: String,
        price_info_object: Option<&PriceInfoObject>,
        clock: &Clock,
    ): (u64, u64) {
        if (option::is_some(&price_info_object)) {
            let price_obj = option::borrow(&price_info_object);
            // Try to get Pyth price first
            let (price, confidence) = get_price_from_pyth(oracle, symbol, price_obj, clock);
            (price, confidence)
        } else {
            // Use fallback price if Pyth is unavailable
            let price_config = table::borrow(&oracle.prices, symbol);
            assert!(price_config.fallback_price > 0, constants::e_invalid_price());
            (price_config.fallback_price, 0)
        }
    }

    public fun set_fallback_price(
        oracle: &mut PriceOracle,
        _admin_cap: &AdminCap,
        symbol: String,
        fallback_price: u64,
        clock: &Clock,
    ) {
        assert!(table::contains(&oracle.prices, symbol), constants::e_invalid_price());
        
        let price_config = table::borrow_mut(&mut oracle.prices, symbol);
        price_config.fallback_price = fallback_price;
        price_config.last_update = clock::timestamp_ms(clock);
    }

    public fun activate_price_feed(
        oracle: &mut PriceOracle,
        _admin_cap: &AdminCap,
        symbol: String,
    ) {
        assert!(table::contains(&oracle.prices, symbol), constants::e_invalid_price());
        
        let price_config = table::borrow_mut(&mut oracle.prices, symbol);
        price_config.is_active = true;
    }

    public fun deactivate_price_feed(
        oracle: &mut PriceOracle,
        _admin_cap: &AdminCap,
        symbol: String,
    ) {
        assert!(table::contains(&oracle.prices, symbol), constants::e_invalid_price());
        
        let price_config = table::borrow_mut(&mut oracle.prices, symbol);
        price_config.is_active = false;
    }

    // Initialize default price feeds
    public fun initialize_default_feeds(
        oracle: &mut PriceOracle,
        admin_cap: &AdminCap,
    ) {
        add_price_feed(oracle, admin_cap, std::string::utf8(b"BTC"), BTC_USD_PRICE_ID, 60);
        add_price_feed(oracle, admin_cap, std::string::utf8(b"ETH"), ETH_USD_PRICE_ID, 60);
        add_price_feed(oracle, admin_cap, std::string::utf8(b"SOL"), SOL_USD_PRICE_ID, 60);
        add_price_feed(oracle, admin_cap, std::string::utf8(b"SUI"), SUI_USD_PRICE_ID, 60);
    }

    // Helper function to calculate powers of 10
    fun pow_10(exp: u8): u64 {
        let result = 1;
        let i = 0;
        while (i < exp) {
            result = result * 10;
            i = i + 1;
        };
        result
    }

    // View functions
    public fun get_price_config(
        oracle: &PriceOracle,
        symbol: String,
    ): (vector<u8>, u64, bool, u64) {
        assert!(table::contains(&oracle.prices, symbol), constants::e_invalid_price());
        
        let config = table::borrow(&oracle.prices, symbol);
        (config.pyth_price_id, config.max_age_seconds, config.is_active, config.fallback_price)
    }

    public fun is_price_feed_active(
        oracle: &PriceOracle,
        symbol: String,
    ): bool {
        if (!table::contains(&oracle.prices, symbol)) {
            return false
        };
        
        let config = table::borrow(&oracle.prices, symbol);
        config.is_active
    }

    // Legacy compatibility function
    public fun get_price(
        oracle: &PriceOracle,
        symbol: String,
        clock: &Clock,
    ): (u64, u64) {
        // This function requires a fallback price to be set
        // In production, you should use get_price_from_pyth with actual PriceInfoObject
        let config = table::borrow(&oracle.prices, symbol);
        assert!(config.fallback_price > 0, constants::e_invalid_price());
        (config.fallback_price, 0)
    }
}