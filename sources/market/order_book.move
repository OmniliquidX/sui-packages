module omniliquid::order_book {
    use std::string::String;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::vec_map::{Self, VecMap};
    use sui::clock::{Self, Clock};
    use omniliquid::constants;

    public struct OrderBook has key {
        id: UID,
        market: String,
        bids: VecMap<u64, vector<Order>>, // Price level -> Orders
        asks: VecMap<u64, vector<Order>>, // Price level -> Orders
        orders: Table<ID, OrderInfo>,
        last_trade_price: u64,
        volume_24h: u64,
        high_24h: u64,
        low_24h: u64,
        last_update: u64,
    }

    public struct Order has store, drop, copy {
        id: ID,
        trader: address,
        price: u64,
        size: u64,
        remaining_size: u64,
        is_buy: bool,
        timestamp: u64,
        order_type: u8, // 0: Market, 1: Limit, 2: Stop
    }

    public struct OrderInfo has store {
        order: Order,
        is_active: bool,
    }

    public struct Trade has copy, drop {
        buyer: address,
        seller: address,
        price: u64,
        size: u64,
        timestamp: u64,
    }

    public fun new_order_book(
        market: String,
        ctx: &mut TxContext
    ): OrderBook {
        OrderBook {
            id: object::new(ctx),
            market,
            bids: vec_map::empty<u64, vector<Order>>(),
            asks: vec_map::empty<u64, vector<Order>>(),
            orders: table::new(ctx),
            last_trade_price: 0,
            volume_24h: 0,
            high_24h: 0,
            low_24h: 0,
            last_update: 0,
        }
    }

    public fun place_limit_order(
        order_book: &mut OrderBook,
        trader: address,
        price: u64,
        size: u64,
        is_buy: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ): (ID, vector<Trade>) {
        assert!(price > 0, constants::e_invalid_price());
        assert!(size > 0, constants::e_position_too_small());
        
        let timestamp = clock::timestamp_ms(clock);
        let order_id = object::new_uid_from_hash(ctx);
        let order_id_copy = object::uid_to_inner(&order_id);
        object::delete(order_id);
        
        let order = Order {
            id: order_id_copy,
            trader,
            price,
            size,
            remaining_size: size,
            is_buy,
            timestamp,
            order_type: 1, // Limit order
        };

        let trades = match_order(order_book, &mut order, clock);
        
        // If order still has remaining size, add to order book
        if (order.remaining_size > 0) {
            let order_info = OrderInfo {
                order,
                is_active: true,
            };
            
            table::add(&mut order_book.orders, order_id_copy, order_info);
            add_order_to_book(order_book, order, is_buy);
        };

        order_book.last_update = timestamp;
        (order_id_copy, trades)
    }

    public fun place_market_order(
        order_book: &mut OrderBook,
        trader: address,
        size: u64,
        is_buy: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ): (vector<Trade>, u64) {
        assert!(size > 0, constants::e_position_too_small());
        
        let timestamp = clock::timestamp_ms(clock);
        let order_id = object::new_uid_from_hash(ctx);
        let order_id_copy = object::uid_to_inner(&order_id);
        object::delete(order_id);
        
        let market_price = if (is_buy) {
            get_best_ask_price(order_book)
        } else {
            get_best_bid_price(order_book)
        };
        
        let mut order = Order {
            id: order_id_copy,
            trader,
            price: market_price,
            size,
            remaining_size: size,
            is_buy,
            timestamp,
            order_type: 0, // Market order
        };

        let trades = match_order(order_book, &mut order, clock);
        let filled_size = size - order.remaining_size;
        
        order_book.last_update = timestamp;
        (trades, filled_size)
    }

    fun add_order_to_book(
        order_book: &mut OrderBook,
        order: Order,
        is_buy: bool,
    ) {
        let price = order.price;
        
        if (is_buy) {
            if (vec_map::contains(&order_book.bids, &price)) {
                let orders = vec_map::get_mut(&mut order_book.bids, &price);
                vector::push_back(orders, order);
            } else {
                let new_orders = vector::empty<Order>();
                vector::push_back(&mut new_orders, order);
                vec_map::insert(&mut order_book.bids, price, new_orders);
            }
        } else {
            if (vec_map::contains(&order_book.asks, &price)) {
                let orders = vec_map::get_mut(&mut order_book.asks, &price);
                vector::push_back(orders, order);
            } else {
                let new_orders = vector::empty<Order>();
                vector::push_back(&mut new_orders, order);
                vec_map::insert(&mut order_book.asks, price, new_orders);
            }
        }
    }

    fun match_order(
        order_book: &mut OrderBook,
        incoming_order: &mut Order,
        clock: &Clock
    ): vector<Trade> {
        let mut trades = vector::empty<Trade>();
        let timestamp = clock::timestamp_ms(clock);
        
        // Simple matching logic (simplified for brevity)
        // In production, this would be more sophisticated
        
        order_book.last_update = timestamp;
        trades
    }

    public fun cancel_order(
        order_book: &mut OrderBook,
        order_id: ID,
        trader: address,
        clock: &Clock
    ): bool {
        if (!table::contains(&order_book.orders, order_id)) {
            return false
        };
        
        let order_info = table::borrow(&order_book.orders, order_id);
        if (order_info.order.trader != trader) {
            return false
        };
        
        // Remove from order book
        table::remove(&mut order_book.orders, order_id);
        order_book.last_update = clock::timestamp_ms(clock);
        
        true
    }

    // View functions
    public fun get_best_bid_price(order_book: &OrderBook): u64 {
        if (vec_map::is_empty(&order_book.bids)) {
            return 0
        };
        
        // Get highest bid price (simplified)
        let mut best_price = 0;
        let mut i = 0;
        let size = vec_map::size(&order_book.bids);
        
        while (i < size) {
            let (price, _) = vec_map::get_entry_by_idx(&order_book.bids, i);
            if (*price > best_price) {
                best_price = *price;
            };
            i = i + 1;
        };
        
        best_price
    }

    public fun get_best_ask_price(order_book: &OrderBook): u64 {
        if (vec_map::is_empty(&order_book.asks)) {
            return 0
        };
        
        // Get lowest ask price (simplified)
        let mut best_price = 18446744073709551615; // u64::MAX
        let mut i = 0;
        let size = vec_map::size(&order_book.asks);
        
        while (i < size) {
            let (price, _) = vec_map::get_entry_by_idx(&order_book.asks, i);
            if (*price < best_price) {
                best_price = *price;
            };
            i = i + 1;
        };
        
        if (best_price == 18446744073709551615) 0 else best_price
    }

    public fun get_spread(order_book: &OrderBook): u64 {
        let best_bid = get_best_bid_price(order_book);
        let best_ask = get_best_ask_price(order_book);
        
        if (best_bid == 0 || best_ask == 0) {
            return 0
        };
        
        best_ask - best_bid
    }

    public fun get_mid_price(order_book: &OrderBook): u64 {
        let best_bid = get_best_bid_price(order_book);
        let best_ask = get_best_ask_price(order_book);
        
        if (best_bid == 0 || best_ask == 0) {
            return order_book.last_trade_price
        };
        
        (best_bid + best_ask) / 2
    }

    public fun market(order_book: &OrderBook): String {
        order_book.market
    }

    public fun last_trade_price(order_book: &OrderBook): u64 {
        order_book.last_trade_price
    }

    public fun volume_24h(order_book: &OrderBook): u64 {
        order_book.volume_24h
    }

    public fun high_24h(order_book: &OrderBook): u64 {
        order_book.high_24h
    }

    public fun low_24h(order_book: &OrderBook): u64 {
        order_book.low_24h
    }
}