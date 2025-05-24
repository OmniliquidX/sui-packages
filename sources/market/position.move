module omniliquid::position {
    use std::string::String;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use omniliquid::math;
    use omniliquid::constants;

    public struct Position has key, store {
        id: UID,
        trader: address,
        market: String,
        size: u64,
        collateral: u64,
        entry_price: u64,
        is_long: bool,
        leverage: u8,
        liquidation_price: u64,
        timestamp: u64,
        last_update: u64,
        stop_loss: Option<u64>,
        take_profit: Option<u64>,
        pending_funding: u64,
    }

    public fun new_position(
        trader: address,
        market: String,
        size: u64,
        collateral: u64,
        entry_price: u64,
        is_long: bool,
        leverage: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ): Position {
        let timestamp = clock::timestamp_ms(clock);
        let liquidation_price = math::calculate_liquidation_price(entry_price, leverage, is_long);
        
        Position {
            id: object::new(ctx),
            trader,
            market,
            size,
            collateral,
            entry_price,
            is_long,
            leverage,
            liquidation_price,
            timestamp,
            last_update: timestamp,
            stop_loss: option::none(),
            take_profit: option::none(),
            pending_funding: 0,
        }
    }

    public fun calculate_pnl(
        position: &Position,
        current_price: u64
    ): (bool, u64) {
        math::calculate_pnl(
            position.entry_price,
            current_price,
            position.size,
            position.is_long
        )
    }

    public fun calculate_margin_ratio(
        position: &Position,
        current_price: u64
    ): u64 {
        let (is_profit, pnl_amount) = calculate_pnl(position, current_price);
        let funding_payment = position.pending_funding;
        
        let effective_margin = if (is_profit) {
            position.collateral + pnl_amount - funding_payment
        } else {
            if (pnl_amount + funding_payment >= position.collateral) {
                0
            } else {
                position.collateral - pnl_amount - funding_payment
            }
        };
        
        let position_value = math::mul_div(
            position.size,
            current_price,
            constants::price_precision()
        );
        
        if (position_value == 0) {
            return constants::bps_precision()
        };
        
        math::mul_div(effective_margin, constants::bps_precision(), position_value)
    }

    public fun is_liquidatable(
        position: &Position,
        current_price: u64
    ): bool {
        let margin_ratio = calculate_margin_ratio(position, current_price);
        margin_ratio <= constants::maintenance_margin_rate()
    }

    public fun update_collateral(
        position: &mut Position,
        new_collateral: u64,
        clock: &Clock
    ) {
        position.collateral = new_collateral;
        position.last_update = clock::timestamp_ms(clock);
        
        // Recalculate liquidation price with new collateral
        let new_leverage = math::mul_div(
            position.size,
            position.entry_price,
            new_collateral * constants::price_precision()
        );
        position.liquidation_price = math::calculate_liquidation_price(
            position.entry_price,
            (new_leverage as u8),
            position.is_long
        );
    }

    public fun set_stop_loss(
        position: &mut Position,
        stop_loss_price: u64,
        clock: &Clock
    ) {
        // Validate stop loss price
        if (position.is_long) {
            assert!(stop_loss_price < position.entry_price, constants::e_invalid_price());
        } else {
            assert!(stop_loss_price > position.entry_price, constants::e_invalid_price());
        };
        
        position.stop_loss = option::some(stop_loss_price);
        position.last_update = clock::timestamp_ms(clock);
    }

    public fun set_take_profit(
        position: &mut Position,
        take_profit_price: u64,
        clock: &Clock
    ) {
        // Validate take profit price
        if (position.is_long) {
            assert!(take_profit_price > position.entry_price, constants::e_invalid_price());
        } else {
            assert!(take_profit_price < position.entry_price, constants::e_invalid_price());
        };
        
        position.take_profit = option::some(take_profit_price);
        position.last_update = clock::timestamp_ms(clock);
    }

    public fun remove_stop_loss(
        position: &mut Position,
        clock: &Clock
    ) {
        position.stop_loss = option::none();
        position.last_update = clock::timestamp_ms(clock);
    }

    public fun remove_take_profit(
        position: &mut Position,
        clock: &Clock
    ) {
        position.take_profit = option::none();
        position.last_update = clock::timestamp_ms(clock);
    }

    public fun should_trigger_stop_loss(
        position: &Position,
        current_price: u64
    ): bool {
        if (option::is_none(&position.stop_loss)) {
            return false
        };
        
        let stop_price = *option::borrow(&position.stop_loss);
        
        if (position.is_long) {
            current_price <= stop_price
        } else {
            current_price >= stop_price
        }
    }

    public fun should_trigger_take_profit(
        position: &Position,
        current_price: u64
    ): bool {
        if (option::is_none(&position.take_profit)) {
            return false
        };
        
        let tp_price = *option::borrow(&position.take_profit);
        
        if (position.is_long) {
            current_price >= tp_price
        } else {
            current_price <= tp_price
        }
    }

    public fun update_funding_payment(
        position: &mut Position,
        funding_payment: u64,
        clock: &Clock
    ) {
        position.pending_funding = position.pending_funding + funding_payment;
        position.last_update = clock::timestamp_ms(clock);
    }

    public fun clear_funding_payment(
        position: &mut Position,
        clock: &Clock
    ) {
        position.pending_funding = 0;
        position.last_update = clock::timestamp_ms(clock);
    }

    // Getters
    public fun id(position: &Position): ID {
        object::uid_to_inner(&position.id)
    }

    public fun trader(position: &Position): address {
        position.trader
    }

    public fun market(position: &Position): String {
        position.market
    }

    public fun size(position: &Position): u64 {
        position.size
    }

    public fun collateral(position: &Position): u64 {
        position.collateral
    }

    public fun entry_price(position: &Position): u64 {
        position.entry_price
    }

    public fun is_long(position: &Position): bool {
        position.is_long
    }

    public fun leverage(position: &Position): u8 {
        position.leverage
    }

    public fun liquidation_price(position: &Position): u64 {
        position.liquidation_price
    }

    public fun timestamp(position: &Position): u64 {
        position.timestamp
    }

    public fun last_update(position: &Position): u64 {
        position.last_update
    }

    public fun stop_loss(position: &Position): Option<u64> {
        position.stop_loss
    }

    public fun take_profit(position: &Position): Option<u64> {
        position.take_profit
    }

    public fun pending_funding(position: &Position): u64 {
        position.pending_funding
    }

    // Destroy position function for closing positions
    public fun destroy_position(position: Position) {
        let Position { 
            id, trader: _, market: _, size: _, collateral: _, entry_price: _, 
            is_long: _, leverage: _, liquidation_price: _, timestamp: _, 
            last_update: _, stop_loss: _, take_profit: _, pending_funding: _ 
        } = position;
        object::delete(id);
    }
}