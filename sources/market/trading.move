module omniliquid::trading {
    use std::string::String;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use pyth::price_info;
    use omniliquid::position::{Self, Position};
    use omniliquid::collateral::{Self, UserCollateral};
    use omniliquid::price_oracle::{Self, PriceOracle};
    use omniliquid::order_book::{Self, OrderBook};
    use omniliquid::treasury::{Self, ProtocolTreasury};
    use omniliquid::math;
    use omniliquid::constants;
    use omniliquid::events;

    public struct MarketState has key {
        id: UID,
        markets: Table<String, MarketInfo>,
        order_books: Table<String, ID>,
        admin: address,
        total_volume: u64,
        total_fees_collected: u64,
        trading_fee_bps: u64,
        funding_rate_multiplier: u64,
        is_emergency_stopped: bool,
    }

    public struct MarketInfo has store {
        symbol: String,
        is_active: bool,
        max_leverage: u8,
        min_position_size: u64,
        max_position_size: u64,
        funding_rate: u64,
        open_interest_long: u64,
        open_interest_short: u64,
        last_funding_update: u64,
    }

    public struct AdminCap has key {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        let market_state = MarketState {
            id: object::new(ctx),
            markets: table::new(ctx),
            order_books: table::new(ctx),
            admin: tx_context::sender(ctx),
            total_volume: 0,
            total_fees_collected: 0,
            trading_fee_bps: 10, // 0.1%
            funding_rate_multiplier: 100, // 1%
            is_emergency_stopped: false,
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        transfer::share_object(market_state);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun add_market(
        market_state: &mut MarketState,
        _admin_cap: &AdminCap,
        symbol: String,
        max_leverage: u8,
        min_position_size: u64,
        max_position_size: u64,
        ctx: &mut TxContext
    ) {
        assert!(!table::contains(&market_state.markets, symbol), constants::e_market_closed());
        
        let market_info = MarketInfo {
            symbol,
            is_active: true,
            max_leverage,
            min_position_size,
            max_position_size,
            funding_rate: 0,
            open_interest_long: 0,
            open_interest_short: 0,
            last_funding_update: 0,
        };

        let order_book = order_book::new_order_book(symbol, ctx);
        let order_book_id = object::id(&order_book);
        
        // Note: In production, you'd need to handle order book sharing differently
        // For now, we'll transfer to the module publisher
        transfer::public_transfer(order_book, market_state.admin);
        
        table::add(&mut market_state.markets, symbol, market_info);
        table::add(&mut market_state.order_books, symbol, order_book_id);
    }

    public fun open_position(
        market_state: &mut MarketState,
        price_oracle: &PriceOracle,
        treasury: &mut ProtocolTreasury,
        market: String,
        collateral_coin: Coin<SUI>,
        size: u64,
        is_long: bool,
        leverage: u8,
        price_info_object: Option<&price_info::PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Position {
        assert!(!market_state.is_emergency_stopped, constants::e_market_closed());
        assert!(table::contains(&market_state.markets, market), constants::e_market_closed());
        
        let market_info = table::borrow_mut(&mut market_state.markets, market);
        assert!(market_info.is_active, constants::e_market_closed());
        assert!(leverage >= constants::min_leverage(), constants::e_invalid_leverage());
        assert!(leverage <= market_info.max_leverage, constants::e_invalid_leverage());
        assert!(size >= market_info.min_position_size, constants::e_position_too_small());
        assert!(size <= market_info.max_position_size, constants::e_position_too_large());

        // Get current price from Pyth oracle
        let (current_price, _) = price_oracle::get_price_with_fallback(
            price_oracle, 
            market, 
            price_info_object, 
            clock
        );
        let collateral_amount = coin::value(&collateral_coin);
        let required_collateral = math::calculate_required_collateral(size, current_price, leverage);
        
        assert!(collateral_amount >= required_collateral, constants::e_insufficient_collateral());

        let trader = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);

        // Calculate trading fee
        let position_value = math::mul_div(size, current_price, constants::price_precision());
        let trading_fee = math::mul_div(position_value, market_state.trading_fee_bps, constants::bps_precision());
        
        // Ensure sufficient collateral after fee
        assert!(collateral_amount >= required_collateral + trading_fee, constants::e_insufficient_collateral());

        // Deposit collateral to treasury
        treasury::deposit(treasury, collateral_coin);

        // Update open interest
        if (is_long) {
            market_info.open_interest_long = market_info.open_interest_long + size;
        } else {
            market_info.open_interest_short = market_info.open_interest_short + size;
        };

        // Update global stats
        market_state.total_volume = market_state.total_volume + position_value;
        market_state.total_fees_collected = market_state.total_fees_collected + trading_fee;

        // Create position
        let position = position::new_position(
            trader,
            market,
            size,
            collateral_amount - trading_fee,
            current_price,
            is_long,
            leverage,
            clock,
            ctx
        );

        // Emit event
        events::emit_position_opened(
            position::id(&position),
            trader,
            market,
            size,
            collateral_amount - trading_fee,
            current_price,
            is_long,
            leverage,
            timestamp
        );

        position
    }

    public fun close_position(
        market_state: &mut MarketState,
        price_oracle: &PriceOracle,
        position: Position,
        is_market_close: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(!market_state.is_emergency_stopped, constants::E_MARKET_CLOSED());
        
        let market = position::market(&position);
        let trader = position::trader(&position);
        let size = position::size(&position);
        let collateral = position::collateral(&position);
        let is_long = position::is_long(&position);
        let entry_price = position::entry_price(&position);
        let position_id = position::id(&position);
        
        assert!(trader == tx_context::sender(ctx), constants::e_unauthorized());
        assert!(table::contains(&market_state.markets, market), constants::e_market_closed());
        
        let (current_price, _) = price_oracle::get_price(price_oracle, market, clock);
        let timestamp = clock::timestamp_ms(clock);
        
        // Calculate PnL
        let (is_profit, pnl_amount) = position::calculate_pnl(&position, current_price);
        let funding_payment = position::pending_funding(&position);
        
        // Calculate final payout
        let mut payout = collateral;
        if (is_profit) {
            payout = payout + pnl_amount;
        } else {
            if (pnl_amount >= payout) {
                payout = 0;
            } else {
                payout = payout - pnl_amount;
            }
        };
        
        // Deduct funding payment
        if (funding_payment >= payout) {
            payout = 0;
        } else {
            payout = payout - funding_payment;
        };
        
        // Calculate closing fee
        let position_value = math::mul_div(size, current_price, constants::PRICE_PRECISION());
        let closing_fee = math::mul_div(position_value, market_state.trading_fee_bps, constants::BPS_PRECISION());
        
        if (closing_fee >= payout) {
            payout = 0;
        } else {
            payout = payout - closing_fee;
        };
        
        // Update open interest
        let market_info = table::borrow_mut(&mut market_state.markets, market);
        if (is_long) {
            market_info.open_interest_long = market_info.open_interest_long - size;
        } else {
            market_info.open_interest_short = market_info.open_interest_short - size;
        };
        
        // Update global stats
        market_state.total_volume = market_state.total_volume + position_value;
        market_state.total_fees_collected = market_state.total_fees_collected + closing_fee;
        
        // Emit event
        events::emit_position_closed(
            position_id,
            trader,
            market,
            size,
            current_price,
            if (is_profit) pnl_amount else pnl_amount,
            is_profit,
            timestamp
        );
        
        // Destroy position (simplified - need proper destruction function)
        position::destroy_position(position);
        
        // Return payout from treasury
        treasury::create_coin(treasury, payout, ctx)
    }

    public fun add_collateral(
        market_state: &MarketState,
        treasury: &mut ProtocolTreasury,
        position: &mut Position,
        additional_collateral: Coin<SUI>,
        clock: &Clock,
    ) {
        assert!(!market_state.is_emergency_stopped, constants::e_market_closed());
        
        let additional_amount = coin::value(&additional_collateral);
        let new_collateral = position::collateral(position) + additional_amount;
        
        // Transfer additional collateral to treasury
        treasury::deposit(treasury, additional_collateral);
        
        // Update position
        position::update_collateral(position, new_collateral, clock);
    }

    public fun remove_collateral(
        market_state: &MarketState,
        price_oracle: &PriceOracle,
        treasury: &mut ProtocolTreasury,
        position: &mut Position,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(!market_state.is_emergency_stopped, constants::e_market_closed());
        assert!(position::trader(position) == tx_context::sender(ctx), constants::e_unauthorized());
        
        let current_collateral = position::collateral(position);
        assert!(amount < current_collateral, constants::e_insufficient_collateral());
        
        let market = position::market(position);
        let (current_price, _) = price_oracle::get_price(price_oracle, market, clock);
        
        // Check if position would still be safe after collateral removal
        let new_collateral = current_collateral - amount;
        position::update_collateral(position, new_collateral, clock);
        
        let margin_ratio = position::calculate_margin_ratio(position, current_price);
        assert!(margin_ratio > constants::maintenance_margin_rate() * 2, constants::e_liquidation_threshold());
        
        // Return removed collateral from treasury
        treasury::create_coin(treasury, amount, ctx)
    }

    public fun set_stop_loss(
        position: &mut Position,
        stop_loss_price: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(position::trader(position) == tx_context::sender(ctx), constants::e_unauthorized());
        position::set_stop_loss(position, stop_loss_price, clock);
    }

    public fun set_take_profit(
        position: &mut Position,
        take_profit_price: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(position::trader(position) == tx_context::sender(ctx), constants::e_unauthorized());
        position::set_take_profit(position, take_profit_price, clock);
    }

    public fun remove_stop_loss(
        position: &mut Position,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(position::trader(position) == tx_context::sender(ctx), constants::e_unauthorized());
        position::remove_stop_loss(position, clock);
    }

    public fun remove_take_profit(
        position: &mut Position,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(position::trader(position) == tx_context::sender(ctx), constants::e_unauthorized());
        position::remove_take_profit(position, clock);
    }

    public fun liquidate_position(
        market_state: &mut MarketState,
        price_oracle: &PriceOracle,
        treasury: &mut ProtocolTreasury,
        position: Position,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let market = position::market(&position);
        let (current_price, _) = price_oracle::get_price(price_oracle, market, clock);
        
        assert!(position::is_liquidatable(&position, current_price), constants::e_liquidation_threshold());
        
        let liquidator = tx_context::sender(ctx);
        let trader = position::trader(&position);
        let size = position::size(&position);
        let collateral = position::collateral(&position);
        let is_long = position::is_long(&position);
        let position_id = position::id(&position);
        let timestamp = clock::timestamp_ms(clock);
        
        // Calculate liquidation fee
        let liquidation_fee = math::mul_div(collateral, constants::liquidation_fee_rate(), constants::bps_precision());
        let remaining_collateral = if (liquidation_fee >= collateral) 0 else collateral - liquidation_fee;
        
        // Update open interest
        let market_info = table::borrow_mut(&mut market_state.markets, market);
        if (is_long) {
            market_info.open_interest_long = market_info.open_interest_long - size;
        } else {
            market_info.open_interest_short = market_info.open_interest_short - size;
        };
        
        // Update global stats
        market_state.total_fees_collected = market_state.total_fees_collected + liquidation_fee;
        
        // Emit liquidation event
        events::emit_position_liquidated(
            position_id,
            trader,
            liquidator,
            market,
            size,
            current_price,
            liquidation_fee,
            timestamp
        );
        
        // Destroy position
        position::destroy_position(position);
        
        // Return liquidation reward to liquidator from treasury
        treasury::create_coin(treasury, liquidation_fee / 2, ctx) // Liquidator gets 50% of fee
    }

    public fun partial_close_position(
        market_state: &mut MarketState,
        price_oracle: &PriceOracle,
        treasury: &mut ProtocolTreasury,
        position: &mut Position,
        close_percentage: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(!market_state.is_emergency_stopped, constants::e_market_closed());
        assert!(position::trader(position) == tx_context::sender(ctx), constants::e_unauthorized());
        assert!(close_percentage > 0 && close_percentage <= 100, constants::e_invalid_price());
        
        let market = position::market(position);
        let (current_price, _) = price_oracle::get_price(price_oracle, market, clock);
        let timestamp = clock::timestamp_ms(clock);
        
        let current_size = position::size(position);
        let current_collateral = position::collateral(position);
        let close_size = math::mul_div(current_size, (close_percentage as u64), 100);
        let close_collateral = math::mul_div(current_collateral, (close_percentage as u64), 100);
        
        // Calculate PnL for the portion being closed
        let (is_profit, pnl_amount) = position::calculate_pnl(position, current_price);
        let partial_pnl = math::mul_div(pnl_amount, (close_percentage as u64), 100);
        
        // Calculate payout
        let mut payout = close_collateral;
        if (is_profit) {
            payout = payout + partial_pnl;
        } else {
            if (partial_pnl >= payout) {
                payout = 0;
            } else {
                payout = payout - partial_pnl;
            }
        };
        
        // Calculate closing fee
        let position_value = math::mul_div(close_size, current_price, constants::price_precision());
        let closing_fee = math::mul_div(position_value, market_state.trading_fee_bps, constants::bps_precision());
        
        if (closing_fee >= payout) {
            payout = 0;
        } else {
            payout = payout - closing_fee;
        };
        
        // Update position size and collateral
        let new_size = current_size - close_size;
        let new_collateral = current_collateral - close_collateral;
        
        // This is simplified - in production you'd need to update the position struct properly
        // For now, we'll assume the position module has update functions
        
        // Update open interest
        let market_info = table::borrow_mut(&mut market_state.markets, market);
        let is_long = position::is_long(position);
        if (is_long) {
            market_info.open_interest_long = market_info.open_interest_long - close_size;
        } else {
            market_info.open_interest_short = market_info.open_interest_short - close_size;
        };
        
        // Update global stats
        market_state.total_volume = market_state.total_volume + position_value;
        market_state.total_fees_collected = market_state.total_fees_collected + closing_fee;
        
        // Return payout from treasury
        treasury::create_coin(treasury, payout, ctx)
    }

    // Emergency functions
    public fun emergency_stop(
        market_state: &mut MarketState,
        _admin_cap: &AdminCap,
    ) {
        market_state.is_emergency_stopped = true;
    }

    public fun resume_trading(
        market_state: &mut MarketState,
        _admin_cap: &AdminCap,
    ) {
        market_state.is_emergency_stopped = false;
    }

    // View functions
    public fun get_market_info(
        market_state: &MarketState,
        market: String
    ): (bool, u8, u64, u64, u64, u64, u64) {
        if (!table::contains(&market_state.markets, market)) {
            return (false, 0, 0, 0, 0, 0, 0)
        };
        
        let market_info = table::borrow(&market_state.markets, market);
        (
            market_info.is_active,
            market_info.max_leverage,
            market_info.min_position_size,
            market_info.max_position_size,
            market_info.funding_rate,
            market_info.open_interest_long,
            market_info.open_interest_short
        )
    }

    public fun total_volume(market_state: &MarketState): u64 {
        market_state.total_volume
    }

    public fun total_fees_collected(market_state: &MarketState): u64 {
        market_state.total_fees_collected
    }

    public fun trading_fee_bps(market_state: &MarketState): u64 {
        market_state.trading_fee_bps
    }

    public fun is_emergency_stopped(market_state: &MarketState): bool {
        market_state.is_emergency_stopped
    }
}

    // Emergency functions
    public fun emergency_stop(
        market_state: &mut MarketState,
        _admin_cap: &AdminCap,
    ) {
        market_state.is_emergency_stopped = true;
    }

    public fun resume_trading(
        market_state: &mut MarketState,
        _admin_cap: &AdminCap,
    ) {
        market_state.is_emergency_stopped = false;
    }

    // View functions
    public fun get_market_info(
        market_state: &MarketState,
        market: String
    ): (bool, u8, u64, u64, u64, u64, u64) {
        if (!table::contains(&market_state.markets, market)) {
            return (false, 0, 0, 0, 0, 0, 0)
        };
        
        let market_info = table::borrow(&market_state.markets, market);
        (
            market_info.is_active,
            market_info.max_leverage,
            market_info.min_position_size,
            market_info.max_position_size,
            market_info.funding_rate,
            market_info.open_interest_long,
            market_info.open_interest_short
        )
    }

    public fun total_volume(market_state: &MarketState): u64 {
        market_state.total_volume
    }

    public fun total_fees_collected(market_state: &MarketState): u64 {
        market_state.total_fees_collected
    }

    public fun trading_fee_bps(market_state: &MarketState): u64 {
        market_state.trading_fee_bps
    }

    public fun is_emergency_stopped(market_state: &MarketState): bool {
        market_state.is_emergency_stopped
    }