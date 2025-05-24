#[test_only]
module omniliquid::market_tests {
    use sui::test_scenario::{Self, Scenario, next_tx, ctx};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use std::string;
    use omniliquid::trading::{Self, MarketState, AdminCap};
    use omniliquid::collateral::{Self, UserCollateral};
    use omniliquid::price_oracle::{Self, PriceOracle};
    use omniliquid::position::Position;
    use omniliquid::constants;

    const ADMIN: address = @0xAD;
    const TRADER: address = @0xBEEF;
    const LIQUIDATOR: address = @0xCAFE;

    #[test]
    fun test_market_initialization() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // Initialize market
        next_tx(scenario, ADMIN);
        {
            trading::init_for_testing(ctx(scenario));
        };
        
        // Check market state exists
        next_tx(scenario, ADMIN);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            
            assert!(trading::total_volume(&market_state) == 0, 0);
            assert!(trading::total_fees_collected(&market_state) == 0, 0);
            assert!(!trading::is_emergency_stopped(&market_state), 0);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_add_market() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // Initialize
        next_tx(scenario, ADMIN);
        {
            trading::init_for_testing(ctx(scenario));
            price_oracle::init_for_testing(ctx(scenario));
        };
        
        // Add BTC market
        next_tx(scenario, ADMIN);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            
            trading::add_market(
                &mut market_state,
                &admin_cap,
                string::utf8(b"BTC"),
                50, // max leverage
                1000000, // min position size (0.001 BTC)
                1000000000000, // max position size (1000 BTC)
                ctx(scenario)
            );
            
            let (is_active, max_leverage, min_size, max_size, funding_rate, oi_long, oi_short) = 
                trading::get_market_info(&market_state, string::utf8(b"BTC"));
            
            assert!(is_active, 0);
            assert!(max_leverage == 50, 0);
            assert!(min_size == 1000000, 0);
            assert!(max_size == 1000000000000, 0);
            assert!(funding_rate == 0, 0);
            assert!(oi_long == 0, 0);
            assert!(oi_short == 0, 0);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_collateral_deposit_withdraw() {
        let scenario_val = test_scenario::begin(TRADER);
        let scenario = &mut scenario_val;
        
        // Initialize clock
        next_tx(scenario, TRADER);
        {
            let clock = clock::create_for_testing(ctx(scenario));
            clock::set_for_testing(&mut clock, 1000000); // Set timestamp
            clock::share_for_testing(clock);
        };
        
        // Deposit collateral
        next_tx(scenario, TRADER);
        {
            let clock = test_scenario::take_shared<Clock>(scenario);
            let deposit_coin = coin::mint_for_testing<SUI>(1000000000, ctx(scenario)); // 1 SUI
            
            collateral::create_and_deposit_entry(deposit_coin, &clock, ctx(scenario));
            
            test_scenario::return_shared(clock);
        };
        
        // Check collateral
        next_tx(scenario, TRADER);
        {
            let collateral = test_scenario::take_from_sender<UserCollateral>(scenario);
            
            assert!(collateral::total_amount(&collateral) == 1000000000, 0);
            assert!(collateral::available_amount(&collateral) == 1000000000, 0);
            assert!(collateral::owner(&collateral) == TRADER, 0);
            
            test_scenario::return_to_sender(scenario, collateral);
        };
        
        // Withdraw some collateral
        next_tx(scenario, TRADER);
        {
            let collateral = test_scenario::take_from_sender<UserCollateral>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            collateral::withdraw_entry(&mut collateral, 500000000, &clock, ctx(scenario)); // 0.5 SUI
            
            assert!(collateral::total_amount(&collateral) == 500000000, 0);
            assert!(collateral::available_amount(&collateral) == 500000000, 0);
            
            test_scenario::return_to_sender(scenario, collateral);
            test_scenario::return_shared(clock);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_open_position() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // Setup
        next_tx(scenario, ADMIN);
        {
            trading::init_for_testing(ctx(scenario));
            price_oracle::init_for_testing(ctx(scenario));
            let clock = clock::create_for_testing(ctx(scenario));
            clock::set_for_testing(&mut clock, 1000000);
            clock::share_for_testing(clock);
        };
        
        // Add market and set price
        next_tx(scenario, ADMIN);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let price_oracle = test_scenario::take_shared<PriceOracle>(scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let oracle_admin_cap = test_scenario::take_from_sender<price_oracle::AdminCap>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            trading::add_market(
                &mut market_state,
                &admin_cap,
                string::utf8(b"BTC"),
                10,
                1000000,
                1000000000000,
                ctx(scenario)
            );
            
            price_oracle::update_price(
                &mut price_oracle,
                &oracle_admin_cap,
                string::utf8(b"BTC"),
                50000000000000, // $50,000
                100,
                &clock
            );
            
            test_scenario::return_shared(market_state);
            test_scenario::return_shared(price_oracle);
            test_scenario::return_shared(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_to_sender(scenario, oracle_admin_cap);
        };
        
        // Open position as trader
        next_tx(scenario, TRADER);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let price_oracle = test_scenario::take_shared<PriceOracle>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            let collateral_coin = coin::mint_for_testing<SUI>(1000000000, ctx(scenario)); // 1 SUI
            
            let position = trading::open_position(
                &mut market_state,
                &price_oracle,
                string::utf8(b"BTC"),
                collateral_coin,
                100000000, // 0.1 BTC
                true, // long
                5, // 5x leverage
                &clock,
                ctx(scenario)
            );
            
            // Check position properties
            assert!(omniliquid::position::trader(&position) == TRADER, 0);
            assert!(omniliquid::position::market(&position) == string::utf8(b"BTC"), 0);
            assert!(omniliquid::position::size(&position) == 100000000, 0);
            assert!(omniliquid::position::is_long(&position), 0);
            assert!(omniliquid::position::leverage(&position) == 5, 0);
            
            transfer::public_transfer(position, TRADER);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_shared(price_oracle);
            test_scenario::return_shared(clock);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_position_liquidation() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // Setup market and position (similar to test_open_position)
        setup_market_and_position(scenario);
        
        // Change price to trigger liquidation
        next_tx(scenario, ADMIN);
        {
            let price_oracle = test_scenario::take_shared<PriceOracle>(scenario);
            let oracle_admin_cap = test_scenario::take_from_sender<price_oracle::AdminCap>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            // Set BTC price to $30,000 (significant drop to trigger liquidation)
            price_oracle::update_price(
                &mut price_oracle,
                &oracle_admin_cap,
                string::utf8(b"BTC"),
                30000000000000,
                100,
                &clock
            );
            
            test_scenario::return_shared(price_oracle);
            test_scenario::return_shared(clock);
            test_scenario::return_to_sender(scenario, oracle_admin_cap);
        };
        
        // Liquidate position
        next_tx(scenario, LIQUIDATOR);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let price_oracle = test_scenario::take_shared<PriceOracle>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            // Take position from trader
            let position = test_scenario::take_from_address<Position>(scenario, TRADER);
            
            // Verify position is liquidatable
            let (current_price, _) = price_oracle::get_price(&price_oracle, string::utf8(b"BTC"), &clock);
            assert!(omniliquid::position::is_liquidatable(&position, current_price), 0);
            
            let liquidation_reward = trading::liquidate_position(
                &mut market_state,
                &price_oracle,
                position,
                &clock,
                ctx(scenario)
            );
            
            // Liquidator should receive some reward
            assert!(coin::value(&liquidation_reward) > 0, 0);
            
            coin::burn_for_testing(liquidation_reward);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_shared(price_oracle);
            test_scenario::return_shared(clock);
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_emergency_stop() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        // Initialize
        next_tx(scenario, ADMIN);
        {
            trading::init_for_testing(ctx(scenario));
        };
        
        // Emergency stop
        next_tx(scenario, ADMIN);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            
            assert!(!trading::is_emergency_stopped(&market_state), 0);
            
            trading::emergency_stop(&mut market_state, &admin_cap);
            
            assert!(trading::is_emergency_stopped(&market_state), 0);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        
        // Resume trading
        next_tx(scenario, ADMIN);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            
            trading::resume_trading(&mut market_state, &admin_cap);
            
            assert!(!trading::is_emergency_stopped(&market_state), 0);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        
        test_scenario::end(scenario_val);
    }

    // Helper function to setup market and position for tests
    fun setup_market_and_position(scenario: &mut Scenario) {
        // Initialize systems
        next_tx(scenario, ADMIN);
        {
            trading::init_for_testing(ctx(scenario));
            price_oracle::init_for_testing(ctx(scenario));
            let clock = clock::create_for_testing(ctx(scenario));
            clock::set_for_testing(&mut clock, 1000000);
            clock::share_for_testing(clock);
        };
        
        // Add market and set price
        next_tx(scenario, ADMIN);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let price_oracle = test_scenario::take_shared<PriceOracle>(scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
            let oracle_admin_cap = test_scenario::take_from_sender<price_oracle::AdminCap>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            trading::add_market(
                &mut market_state,
                &admin_cap,
                string::utf8(b"BTC"),
                10,
                1000000,
                1000000000000,
                ctx(scenario)
            );
            
            price_oracle::update_price(
                &mut price_oracle,
                &oracle_admin_cap,
                string::utf8(b"BTC"),
                50000000000000,
                100,
                &clock
            );
            
            test_scenario::return_shared(market_state);
            test_scenario::return_shared(price_oracle);
            test_scenario::return_shared(clock);
            test_scenario::return_to_sender(scenario, admin_cap);
            test_scenario::return_to_sender(scenario, oracle_admin_cap);
        };
        
        // Open position
        next_tx(scenario, TRADER);
        {
            let market_state = test_scenario::take_shared<MarketState>(scenario);
            let price_oracle = test_scenario::take_shared<PriceOracle>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            let collateral_coin = coin::mint_for_testing<SUI>(1000000000, ctx(scenario));
            
            let position = trading::open_position(
                &mut market_state,
                &price_oracle,
                string::utf8(b"BTC"),
                collateral_coin,
                100000000,
                true,
                5,
                &clock,
                ctx(scenario)
            );
            
            transfer::public_transfer(position, TRADER);
            
            test_scenario::return_shared(market_state);
            test_scenario::return_shared(price_oracle);
            test_scenario::return_shared(clock);
        };
    }
}