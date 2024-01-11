import credits.leo;
import arcanetoken.leo;

program arcane_amm_v3_0.aleo {

    const SELF_ADDRESS: address = aleo1hy8w46tflux7zwpeaw8ny7tq6wkzqux40z75a9ah3q9tqa4t758qltkqu7;
    const MAX_U64: u64 = 18446744073709551615u64;

    const MIN_TICK: i32 = -887272i32;
    const MAX_TICK: i32 = 887272i32;

    /// ██████████████████████████████████████████████████████████████████████
    ///                             Private AMM Swaps
    /// ██████████████████████████████████████████████████████████████████████

    ///  Pools
    struct PoolKey {
        token1: u64,
        token2: u64,
    }

    struct PoolTickKey {
        token1: u64,
        token2: u64,
        tick: i32
    }

    record PoolAdmin {
        owner: address,
        pool_key: field
    }

    // immutable pool data
    struct PoolMeta {
        id: field, // hash(token1.id, token2.id)
        token1_id: u64,
        token2_id: u64,
        tick_spacing: u8,
        max_liq_per_tick: u64,
    }

    // mutable pool data
    struct PoolState {
        tick: i32, // the current tick
        sqrt_price_x24: u64,
        liquidity: u64,
        t1_protocol_fees: u64,
        t2_protocol_fees: u64,
        feeGrowthGlobal0X32: u64,
        feeGrowthGlobal1X32: u64,
        swap_fee: u64, // 10000 based, 1 = 0.01% = 0.0001
    }

    struct PositionKey {
        holder: address,
        pool_key: field,
        position_id: field,
    }

    record PositionReceipt {
        owner: address,
        token1_id: u64,
        token2_id: u64,
        position_id: field
    }

    ///  Extra amount
    struct ExtraAmount {
        token_id: u64,
        token_amount: u64,
    }

    record ExtraAmountVoucher {
             owner: address,
             token_id: u64,
             voucher: field,
    }

    mapping map_pool_meta: field => PoolMeta; // PoolMeta by hash(token1.id, token2.id)
    mapping map_pool_state: field => PoolState; // PoolState by hash(token1.id, token2.id)

    mapping map_tick_info: field => TickInfo; // TickInfo by hash(pool_tick_key)
    mapping map_tick_initialized: field => bool; // tick initialized true/false by hash(pool_tick_key)
    mapping map_position: field => PositionInfo; // all opened positions key TBD

    mapping map_extra_voucher: field => ExtraAmount; // extra amount by voucher_id

    inline get_pool_key(token1: u64, token2: u64) -> field {
        let actual_token1: u64 = token1 > token2 ? token2 : token1;
        let actual_token2: u64 = token1 <= token2 ? token2 : token1;
        return BHP256::hash_to_field(PoolKey {token1: actual_token1, token2: actual_token2});
    }

    inline get_pool_tick_key(token1: u64, token2: u64, tick: i32) -> field {
        let actual_token1: u64 = token1 > token2 ? token2 : token1;
        let actual_token2: u64 = token1 <= token2 ? token2 : token1;
        return BHP256::hash_to_field(PoolTickKey {token1: actual_token1, token2: actual_token2, tick: tick});
    }

    transition create_pool(
        owner: address,
        token1_id: u64,
        token2_id: u64,
        sqrt_price_x24: u64,
        swap_fee: u64, // 10000 based, 1 = 0.01% = 0.0001
        tick_spacing: u8) -> (PoolAdmin) {
        assert(swap_fee <= 10000u64);
        assert(token1_id < token2_id);

        let pool_key: field = get_pool_key(token1_id, token2_id);

        let pool_admin: PoolAdmin = PoolAdmin {
            owner: owner,
            pool_key: pool_key
        };

        return (pool_admin) then finalize(pool_key, token1_id, token2_id, sqrt_price_x24, swap_fee, tick_spacing);
    }

    finalize create_pool(
            pool_key: field,
            token1_id: u64,
            token2_id: u64,
            sqrt_price_x24: u64,
            swap_fee: u64, // 10000 based, 1 = 0.01% = 0.0001
            tick_spacing: u8) {
        assert(!Mapping::contains(map_pool_meta, pool_key)); // the pool already exists
        assert(!Mapping::contains(map_pool_state, pool_key)); // the pool already exists

        let pool_meta: PoolMeta = PoolMeta {
            id: pool_key, // hash(token1.id, token2.id)
            token1_id: token1_id,
            token2_id: token2_id,
            tick_spacing: tick_spacing,
            max_liq_per_tick: get_max_liq_per_tick(tick_spacing),
        };

        let tick: i32 = get_tick_by_price(sqrt_price_x24);
        let pool_state: PoolState = PoolState {
            swap_fee: swap_fee,
            tick: tick,
            sqrt_price_x24: sqrt_price_x24,
            liquidity: 0u64,
            t1_protocol_fees: 0u64,
            t2_protocol_fees: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(map_pool_meta, pool_key, pool_meta);
        Mapping::set(map_pool_state, pool_key, pool_state);
    }

    inline get_max_liq_per_tick(tick_spacing: u8) -> u64 {
        return 1000000000000u64; // todo
    }

    inline get_tick_by_price(price: u64) -> i32 {
        return 0i32; // todo
    }

    inline get_price_by_tick(tick: i32) -> u64 {
        return 0u64; // todo
    }

    transition transfer_pool_ownership(poolAdmin: PoolAdmin, to: address) -> (PoolAdmin) {
        assert(poolAdmin.owner == self.caller);
        return PoolAdmin {
            owner: to,
            pool_key: poolAdmin.pool_key
        };
    }

    transition create_position(owner: address,
                               tick_lower: i32,
                               tick_upper: i32,
                               token1: arcanetoken.leo/ArcaneToken,
                               token1_amount: u64,
                               extra_voucher_1: field,
                               token2: arcanetoken.leo/ArcaneToken,
                               token2_amount: u64,
                               extra_voucher_2: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, PositionReceipt, ExtraAmountVoucher, ExtraAmountVoucher) {
        check_ticks(tick_lower, tick_upper);

        let position_id: field = get_position_info_key(owner, tick_lower, tick_upper);

        let token1_change_record: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token1, SELF_ADDRESS, token1_amount as u128);
        let token2_change_record: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token2, SELF_ADDRESS, token2_amount as u128);

        let position_receipt: PositionReceipt = PositionReceipt {
            owner: owner,
            token1_id: token1.token_id,
            token2_id: token2.token_id,
            position_id: position_id
        };

        // user can get change using this voucher if amount_in is less than actual amount they could swap
        let extra_amount_voucher_1: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: owner,
            token_id: token1.token_id,
            voucher: extra_voucher_1
        };

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher_2: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: owner,
            token_id: token2.token_id,
            voucher: extra_voucher_2
        };

        return (token1_change_record, token2_change_record, position_receipt, extra_amount_voucher_1, extra_amount_voucher_2) then finalize(position_id, tick_lower, tick_upper, token1.token_id, token1_amount, token2.token_id, token2_amount, extra_voucher_1, extra_voucher_2);
    }

    finalize create_position(
        position_id: field,
        tick_lower: i32,
        tick_upper: i32,
        token1_id: u64,
        token1_amount: u64,
        token2_id: u64,
        token2_amount: u64,
        extra_amount_voucher_1: field,
        extra_amount_voucher_2: field) {
        assert(!Mapping::contains(map_position, position_id));

        let pool_key: field = get_pool_key(token1_id, token2_id);
        let pool_meta: PoolMeta = Mapping::get(map_pool_meta, pool_key);
        let pool_state: PoolState = Mapping::get(map_pool_state, pool_key);

        assert(pool_meta.token1_id == token1_id);
        assert(pool_meta.token2_id == token2_id);

        let lower_tick_info: TickInfo = empty_tick_info();
        let lower_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_lower);
        if (Mapping::contains(map_tick_info, lower_tick_key)) {
            lower_tick_info = Mapping::get(map_tick_info, lower_tick_key);
        }

        let upper_tick_info: TickInfo = empty_tick_info();
        let upper_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_upper);
        if (Mapping::contains(map_tick_info, upper_tick_key)) {
            upper_tick_info = Mapping::get(map_tick_info, upper_tick_key);
        }

        let liquidity_delta: i64 = 0i64;
        if (token1_amount != 0u64 && token2_amount != 0u64) {
            liquidity_delta = (token1_amount * token2_amount) as i64;
        } else if (token1_amount == 0u64) {
            liquidity_delta = token2_amount as i64;
        } else {
            liquidity_delta = token1_amount as i64;
        }

        let params: ModifyPositionParams = ModifyPositionParams {
                orig_position: empty_position_info(),
                tick_lower: tick_lower,
                tick_upper: tick_upper,
                lower_tick_info: lower_tick_info,
                upper_tick_info: upper_tick_info,
                liquidity_delta: liquidity_delta,
                pool_meta: pool_meta,
                pool_state: pool_state,
        };
        let result: ModifyPositionResult = modify_position(params);

        let token1_amount_actual: u64 = result.token1_amount.abs() as u64;
        let token2_amount_actual: u64 = result.token2_amount.abs() as u64;
        if (token1_amount == 0u64) {
            assert(token1_amount_actual == 0u64);
        }
        if (token2_amount == 0u64) {
            assert(token2_amount_actual == 0u64);
        }
        assert(token1_amount_actual <= token1_amount);
        assert(token2_amount_actual <= token2_amount);

        let extra_change_1: u64 = token1_amount - token1_amount_actual;
        if (extra_change_1 > 0u64) {
            let extra_amount_1: ExtraAmount = ExtraAmount {
                token_id: token1_id,
                token_amount: extra_change_1,
            };
            Mapping::set(map_extra_voucher, extra_amount_voucher_1, extra_amount_1);
        }

        let extra_change_2: u64 = token2_amount - token2_amount_actual;
        if (extra_change_2 > 0u64) {
            let extra_amount_2: ExtraAmount = ExtraAmount {
                token_id: token2_id,
                token_amount: extra_change_2,
            };
            Mapping::set(map_extra_voucher, extra_amount_voucher_2, extra_amount_2);
        }

        let effects: UpdatePositionResult = result.update_position_result;
        Mapping::set(map_position, position_id, effects.modified_position);
        if (!effects.effect_update_lower_tick.is_empty) {
            Mapping::set(map_tick_info, effects.effect_update_lower_tick.tick_key, effects.effect_update_lower_tick.tick_info);
        }
        if (!effects.effect_update_upper_tick.is_empty) {
            Mapping::set(map_tick_info, effects.effect_update_upper_tick.tick_key, effects.effect_update_upper_tick.tick_info);
        }
        if (!effects.effect_flip_lower_tick.is_empty) {
            let lower_inited: bool = Mapping::get_or_use(map_tick_initialized, lower_tick_key, false);
            Mapping::set(map_tick_initialized, lower_tick_key, !lower_inited);
        }
        if (!effects.effect_flip_upper_tick.is_empty) {
            let upper_inited: bool = Mapping::get_or_use(map_tick_initialized, upper_tick_key, false);
            Mapping::set(map_tick_initialized, upper_tick_key, !upper_inited);
        }
        if (!effects.effect_clear_lower_tick.is_empty) {
            Mapping::remove(map_tick_info, lower_tick_key);
        }
        if (!effects.effect_clear_upper_tick.is_empty) {
            Mapping::remove(map_tick_info, upper_tick_key);
        }

        let liquidity_after: u64 = result.liquidity_after;
        if (liquidity_after != pool_state.liquidity) {
            Mapping::set(map_pool_state, pool_key, PoolState {
                 tick: pool_state.tick,
                 sqrt_price_x24: pool_state.sqrt_price_x24,
                 liquidity: liquidity_after,
                 t1_protocol_fees: pool_state.t1_protocol_fees,
                 t2_protocol_fees: pool_state.t2_protocol_fees,
                 feeGrowthGlobal0X32: pool_state.feeGrowthGlobal0X32,
                 feeGrowthGlobal1X32: pool_state.feeGrowthGlobal1X32,
                 swap_fee: pool_state.swap_fee
            });
        }
    }

    transition close_position(receiver: address,
                              tick_lower: i32,
                              tick_upper: i32,
                              position_receipt: PositionReceipt,
                              token1: arcanetoken.leo/ArcaneToken,
                              token1_amount: u64,
                              extra_voucher_1: field,
                              token2: arcanetoken.leo/ArcaneToken,
                              token2_amount: u64,
                              extra_voucher_2: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher, ExtraAmountVoucher) {
        let token1_change_record: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(token1.token_id, receiver, token1_amount as u128);
        let token2_change_record: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(token2.token_id, receiver, token2_amount as u128);

        // user can get change using this voucher if amount_in is less than actual amount they could swap
        let extra_amount_voucher_1: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token1.token_id,
            voucher: extra_voucher_1
        };

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher_2: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token2.token_id,
            voucher: extra_voucher_2
        };

        let position_id: field = position_receipt.position_id;
        return (token1_change_record, token2_change_record, extra_amount_voucher_1, extra_amount_voucher_2) then finalize(position_id, tick_lower, tick_upper, token1.token_id, token1_amount, token2.token_id, token2_amount, extra_voucher_1, extra_voucher_2);
    }

    finalize close_position(
        position_id: field,
        tick_lower: i32,
        tick_upper: i32,
        token1_id: u64,
        token1_amount: u64,
        token2_id: u64,
        token2_amount: u64,
        extra_amount_voucher_1: field,
        extra_amount_voucher_2: field) {
        assert(Mapping::contains(map_position, position_id));
    
        let position_info: PositionInfo = Mapping::get(map_position, position_id);

        let pool_key: field = get_pool_key(token1_id, token2_id);
        let pool_meta: PoolMeta = Mapping::get(map_pool_meta, pool_key);
        let pool_state: PoolState = Mapping::get(map_pool_state, pool_key);

        assert(pool_meta.token1_id == token1_id);
        assert(pool_meta.token2_id == token2_id);

        let lower_tick_info: TickInfo = empty_tick_info();
        let lower_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_lower);
        if (Mapping::contains(map_tick_info, lower_tick_key)) {
            lower_tick_info = Mapping::get(map_tick_info, lower_tick_key);
        }

        let upper_tick_info: TickInfo = empty_tick_info();
        let upper_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_upper);
        if (Mapping::contains(map_tick_info, upper_tick_key)) {
            upper_tick_info = Mapping::get(map_tick_info, upper_tick_key);
        }

        let liquidity_delta: i64 = 0i64;
        if (token1_amount != 0u64 && token2_amount != 0u64) {
            liquidity_delta = -1i64 * (token1_amount * token2_amount) as i64;
        } else if (token1_amount == 0u64) {
            liquidity_delta = -1i64 * (token2_amount as i64);
        } else {
            liquidity_delta = -1i64 * (token1_amount as i64);
        }

        let params: ModifyPositionParams = ModifyPositionParams {
                orig_position: position_info,
                tick_lower: tick_lower,
                tick_upper: tick_upper,
                lower_tick_info: lower_tick_info,
                upper_tick_info: upper_tick_info,
                liquidity_delta: liquidity_delta,
                pool_meta: pool_meta,
                pool_state: pool_state,
        };
        let result: ModifyPositionResult = modify_position(params);

        let token1_amount_actual: u64 = result.token1_amount.abs() as u64;
        let token2_amount_actual: u64 = result.token2_amount.abs() as u64;
        if (token1_amount == 0u64) {
            assert(token1_amount_actual == 0u64);
        }
        if (token2_amount == 0u64) {
            assert(token2_amount_actual == 0u64);
        }
        assert(token1_amount_actual >= token1_amount);
        assert(token2_amount_actual >= token2_amount);

        let extra_change_1: u64 = token1_amount_actual - token1_amount;
        if (extra_change_1 > 0u64) {
            let extra_amount_1: ExtraAmount = ExtraAmount {
                token_id: token1_id,
                token_amount: extra_change_1
            };
            Mapping::set(map_extra_voucher, extra_amount_voucher_1, extra_amount_1);
        }

        let extra_change_2: u64 = token2_amount_actual - token2_amount;
        if (extra_change_2 > 0u64) {
            let extra_amount_2: ExtraAmount = ExtraAmount {
                token_id: token2_id,
                token_amount: extra_change_2
            };
            Mapping::set(map_extra_voucher, extra_amount_voucher_2, extra_amount_2);
        }

        let effects: UpdatePositionResult = result.update_position_result;
        Mapping::set(map_position, position_id, effects.modified_position);
        if (!effects.effect_update_lower_tick.is_empty) {
            Mapping::set(map_tick_info, effects.effect_update_lower_tick.tick_key, effects.effect_update_lower_tick.tick_info);
        }
        if (!effects.effect_update_upper_tick.is_empty) {
            Mapping::set(map_tick_info, effects.effect_update_upper_tick.tick_key, effects.effect_update_upper_tick.tick_info);
        }
        if (!effects.effect_flip_lower_tick.is_empty) {
            let lower_inited: bool = Mapping::get_or_use(map_tick_initialized, lower_tick_key, false);
            Mapping::set(map_tick_initialized, lower_tick_key, !lower_inited);
        }
        if (!effects.effect_flip_upper_tick.is_empty) {
            let upper_inited: bool = Mapping::get_or_use(map_tick_initialized, upper_tick_key, false);
            Mapping::set(map_tick_initialized, upper_tick_key, !upper_inited);
        }
        if (!effects.effect_clear_lower_tick.is_empty) {
            Mapping::remove(map_tick_info, lower_tick_key);
        }
        if (!effects.effect_clear_upper_tick.is_empty) {
            Mapping::remove(map_tick_info, upper_tick_key);
        }

        let liquidity_after: u64 = result.liquidity_after;
        if (liquidity_after != pool_state.liquidity) {
            Mapping::set(map_pool_state, pool_key, PoolState {
                 tick: pool_state.tick,
                 sqrt_price_x24: pool_state.sqrt_price_x24,
                 liquidity: liquidity_after,
                 t1_protocol_fees: pool_state.t1_protocol_fees,
                 t2_protocol_fees: pool_state.t2_protocol_fees,
                 feeGrowthGlobal0X32: pool_state.feeGrowthGlobal0X32,
                 feeGrowthGlobal1X32: pool_state.feeGrowthGlobal1X32,
                 swap_fee: pool_state.swap_fee
            });
        }
    }


    transition swap(exact_input: bool, receiver: address, token_in: arcanetoken.leo/ArcaneToken, amount_in: u64, token_out_id: u64, amount_out: u64, sqrt_price_limit_x24: u64, extra_voucher_in: field, extra_voucher_out: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher, ExtraAmountVoucher) {
        assert(amount_out > 0u64);

        let change: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token_in, SELF_ADDRESS, amount_in as u128);
        let token_out: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(token_out_id, receiver, amount_out as u128);

        // user can get change using this voucher if amount_in is less than actual amount they could swap
        let extra_amount_voucher_in: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token_in.token_id,
            voucher: extra_voucher_in
        };

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher_out: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token_out.token_id,
            voucher: extra_voucher_out
        };

        return (change, token_out, extra_amount_voucher_in, extra_amount_voucher_out) then finalize(exact_input, token_in.token_id, amount_in, token_out_id, amount_out, sqrt_price_limit_x24, extra_voucher_in, extra_voucher_out);
    }

    finalize swap(exact_input: bool, token_in_id: u64, amount_in: u64, token_out_id: u64, amount_out: u64, sqrt_price_limit_x24: u64, extra_change_voucher_in: field, extra_change_voucher_out: field) {
        let pool_key: field = get_pool_key(token_in_id, token_out_id);
        let pool_meta: PoolMeta = Mapping::get(map_pool_meta, pool_key);
        let pool_state: PoolState = Mapping::get(map_pool_state, pool_key);

        let zeroForOne: bool = token_in_id > token_out_id;
        let amountSpecified: u64 = amount_in;

        assert(
            zeroForOne
                ? sqrt_price_limit_x24 < pool_state.sqrt_price_x24 // && sqrt_price_limit_x24 > TickMath.MIN_SQRT_RATIO todo MIN/MAX sqrt ratio
                : sqrt_price_limit_x24 > pool_state.sqrt_price_x24 // && sqrt_price_limit_x24 < TickMath.MAX_SQRT_RATIO
        );

        // liquidity at the beginning of the swap
        let liquidityStart: u64 = pool_state.liquidity;
        let swap_fee: u64 = pool_state.swap_fee;

        let state_amountSpecifiedRemaining: i64 = amountSpecified as i64;
        let state_amountCalculated: i64 = 0i64;
        let state_sqrt_price_x24: u64 = pool_state.sqrt_price_x24;
        let state_tick: i32 = pool_state.tick;
        let state_feeGrowthGlobalX128: u64 = zeroForOne ? pool_state.feeGrowthGlobal0X32 : pool_state.feeGrowthGlobal1X32;
        let state_protocolFee: u64 = 0u64;
        let state_liquidity: u64 = liquidityStart;

        for i: u32 in 0u32..10u32 {
            // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
            let finished: bool = (state_amountSpecifiedRemaining == 0i64 || state_sqrt_price_x24 == sqrt_price_limit_x24);
            if (!finished) {
                 let step_sqrtPriceStartX24: u64 = state_sqrt_price_x24;
                 let step_tickNext: i32 = 0i32;
                 let step_initialized: bool = false;
                 let step_sqrtPriceNextX24: u64 = 0u64;
                 let step_amountIn: u64 = 0u64;
                 let step_amountOut: u64 = 0u64;
                 let step_feeAmount: u64 = 0u64;

                 let tick_to_check: i32 = state_tick;
                 let found_initialized_tick: bool = false;
                 for j: u32 in 0u32..256u32 {
                     if (!found_initialized_tick) {
                         tick_to_check = zeroForOne ? tick_to_check - (pool_meta.tick_spacing as i32) : tick_to_check + (pool_meta.tick_spacing as i32);
                         let pool_tick_key: field = get_pool_tick_key(pool_meta.token1_id, pool_meta.token2_id, tick_to_check);
                         let tick_initialized: bool = Mapping::get(map_tick_initialized, pool_tick_key);
                         if (tick_initialized && !found_initialized_tick) {
                             found_initialized_tick = true;
                             step_tickNext = tick_to_check;
                             step_initialized = true;
                         }
                     }
                 }
                 if (!found_initialized_tick) {
                     step_tickNext = tick_to_check;
                     step_initialized = false;
                 }

                 // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
                 if (step_tickNext < MIN_TICK) {
                     step_tickNext = MIN_TICK;
                 } else if (step_tickNext > MAX_TICK) {
                     step_tickNext = MAX_TICK;
                 }

                 // get the price for the next tick
                 step_sqrtPriceNextX24 = getSqrtRatioAtTick(step_tickNext);

                 // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted

                 let swap_step_result: ComputeSwapStepResult = computeSwapStep(
                     state_sqrt_price_x24,
                     (zeroForOne ? step_sqrtPriceNextX24 < sqrt_price_limit_x24 : step_sqrtPriceNextX24 > sqrt_price_limit_x24)
                         ? sqrt_price_limit_x24
                         : step_sqrtPriceNextX24,
                     state_liquidity,
                     state_amountSpecifiedRemaining,
                     pool_state.swap_fee
                 );
                 state_sqrt_price_x24 = swap_step_result.sqrtRatioNextX96;
                 step_amountIn = swap_step_result.amountIn;
                 step_amountOut = swap_step_result.amountOut;
                 step_feeAmount = swap_step_result.feeAmount;

                if (exact_input) {
                    state_amountSpecifiedRemaining = state_amountSpecifiedRemaining - ((step_amountIn + step_feeAmount) as i64);
                    state_amountCalculated = state_amountCalculated.sub(step_amountOut as i64);
                } else {
                    state_amountSpecifiedRemaining = state_amountSpecifiedRemaining + step_amountOut as i64;
                    state_amountCalculated = state_amountCalculated.add((step_amountIn + step_feeAmount) as i64);
                }

                 // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
                 if (swap_fee > 0u64) {
                     let delta: u64 = step_feeAmount / swap_fee as u64; // todo fee calculation
                     step_feeAmount = step_feeAmount - delta;
                     state_protocolFee = state_protocolFee + delta;
                 }

                 // update global fee tracker
                 if (state_liquidity > 0u64) {
                    state_feeGrowthGlobalX128 = state_feeGrowthGlobalX128 + mul_div(step_feeAmount, FP_Q32, state_liquidity);
                 }

                 // shift tick if we reached the next price
                 if (state_sqrt_price_x24 == step_sqrtPriceNextX24) {
                     // if the tick is initialized, run the tick transition
                     if (step_initialized) {
                         // check for the placeholder value, which we replace with the actual value the first time the swap
                         // crosses an initialized tick
                         let pool_tick_key: field = get_pool_tick_key(pool_meta.token1_id, pool_meta.token2_id, step_tickNext);
                         let next_tick_info: TickInfo = Mapping::get(map_tick_info, pool_tick_key);

                         let updated_next_tick_info: TickInfo = cross(
                                 next_tick_info,
                                 (zeroForOne ? state_feeGrowthGlobalX128 : pool_state.feeGrowthGlobal0X32),
                                 (zeroForOne ? pool_state.feeGrowthGlobal1X32 : state_feeGrowthGlobalX128)
                             );
                         let liquidityNet: i64 = updated_next_tick_info.liquidityNet;
                         Mapping::set(map_tick_info, pool_tick_key, updated_next_tick_info);

                         // if we're moving leftward, we interpret liquidityNet as the opposite sign
                         // safe because liquidityNet cannot be type(int128).min
                         if (zeroForOne) {
                            liquidityNet = -liquidityNet;
                         }
                         state_liquidity = lm_add_delta(state_liquidity, liquidityNet);
                     }
                     state_tick = zeroForOne ? step_tickNext - 1i32 : step_tickNext;
                 } else if (state_sqrt_price_x24 != step_sqrtPriceStartX24) {
                     // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                     state_tick = get_tick_by_price(state_sqrt_price_x24);
                 }
            }
        }

        let pool_state_sqrt_price_x24: u64 = pool_state.sqrt_price_x24;
        let pool_state_tick: i32 = pool_state.tick;
        let pool_state_liquidity: u64 = pool_state.liquidity;
        let pool_state_feeGrowthGlobal0X128: u64 = pool_state.feeGrowthGlobal0X32;
        let pool_state_feeGrowthGlobal1X128: u64 = pool_state.feeGrowthGlobal1X32;
        let pool_state_t1_protocol_fees: u64 = pool_state.t1_protocol_fees;
        let pool_state_t2_protocol_fees: u64 = pool_state.t2_protocol_fees;

        // update tick and write an oracle entry if the tick change
        if (state_tick != pool_state.tick) {
            pool_state_sqrt_price_x24 = state_sqrt_price_x24;
            pool_state_tick = state_tick;
        } else {
            // otherwise just update the price
            pool_state_sqrt_price_x24 = state_sqrt_price_x24;
        }

        // update liquidity if it changed
        if (liquidityStart != state_liquidity) {
            pool_state_liquidity = state_liquidity;
        }

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        if (zeroForOne) {
            pool_state_feeGrowthGlobal0X128 = state_feeGrowthGlobalX128;
            if (state_protocolFee > 0u64) {
                 pool_state_t1_protocol_fees = pool_state_t1_protocol_fees + state_protocolFee;
            }
        } else {
            pool_state_feeGrowthGlobal1X128 = state_feeGrowthGlobalX128;
            if (state_protocolFee > 0u64) {
                pool_state_t2_protocol_fees = pool_state_t2_protocol_fees + state_protocolFee;
            }
        }

        let updated_pool_state: PoolState = PoolState {
                    tick: pool_state_tick,
                    sqrt_price_x24: pool_state_sqrt_price_x24,
                    liquidity: pool_state_liquidity,
                    t1_protocol_fees: pool_state_t1_protocol_fees,
                    t2_protocol_fees: pool_state_t2_protocol_fees,
                    feeGrowthGlobal0X32: pool_state_feeGrowthGlobal0X128,
                    feeGrowthGlobal1X32: pool_state_feeGrowthGlobal1X128,
                    swap_fee: pool_state.swap_fee
                };
        Mapping::set(map_pool_state, pool_key, updated_pool_state);

        let amount1: i64 = (zeroForOne == exact_input) ? ((amountSpecified as i64) - state_amountSpecifiedRemaining) : state_amountCalculated;
        let amount2: i64 = (zeroForOne == exact_input) ? state_amountCalculated : ((amountSpecified as i64) - state_amountSpecifiedRemaining);

        if (zeroForOne) {
            // amount1 is amount_in
            // amount2 amount_out
            if (amount2 < 0i64) {
                let amount2_abs: u64 = amount2.abs() as u64;
                assert(amount_out <= amount2_abs);
                // Return token out change
                let extra_change_out: u64 = amount2_abs - amount_out;
                let extra_amount_out: ExtraAmount = ExtraAmount {
                    token_id: token_out_id,
                    token_amount: extra_change_out,
                };
                Mapping::set(map_extra_voucher, extra_change_voucher_out, extra_amount_out);
            }
            let amount1_abs: u64 = amount1.abs() as u64;
            assert(amount1_abs <= amount_in);
            // Return token out change
            let extra_change_in: u64 = amount_in - amount1_abs;
            let extra_amount_in: ExtraAmount = ExtraAmount {
                token_id: token_in_id,
                token_amount: extra_change_in,
            };
            Mapping::set(map_extra_voucher, extra_change_voucher_in, extra_amount_in);
        } else {
            // amount1 is amount_out
            // amount2 is amount_in
            if (amount1 < 0i64) {
                let amount1_abs: u64 = amount1.abs() as u64;
                assert(amount_out <= amount1_abs);
                // Return token out change
                let extra_change_out: u64 = amount1_abs - amount_out;
                let extra_amount_out: ExtraAmount = ExtraAmount {
                    token_id: token_out_id,
                    token_amount: extra_change_out,
                };
                Mapping::set(map_extra_voucher, extra_change_voucher_out, extra_amount_out);
            }
            let amount2_abs: u64 = amount2.abs() as u64;
            assert(amount2_abs <= amount_in);
            // Return token out change
            let extra_change_in: u64 = amount_in - amount2_abs;
            let extra_amount_in: ExtraAmount = ExtraAmount {
                token_id: token_in_id,
                token_amount: extra_change_in,
            };
            Mapping::set(map_extra_voucher, extra_change_voucher_in, extra_amount_in);
        }
    }

    transition redeem_voucher(voucher: ExtraAmountVoucher, amount: u64) -> (arcanetoken.leo/ArcaneToken) {
        let token: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(voucher.token_id, voucher.owner, amount as u128);
        return token then finalize(voucher.token_id, voucher.voucher, amount);
    }

    finalize redeem_voucher(token_id: u64, voucher_code: field, amount: u64) {
        let extra: ExtraAmount = Mapping::get(map_extra_voucher, voucher_code);
        assert (extra.token_id == token_id && extra.token_amount == amount);
        Mapping::remove(map_extra_voucher, voucher_code);
    }

    /// ██████████████████████████████████████████████████████████████████████
    ///                             DEMO
    /// ██████████████████████████████████████████████████████████████████████

//     transition init_demo_pools(dummy: field) {
//         return then finalize();
//     }
//
//     finalize init_demo_pools() {
//         let reserve1: u128 = 100000000000000u128;
//         let reserve2: u128 = 100000000000000u128;
//         let reserve3: u128 = 50000000000u128;
//         let reserve4: u128 = 500000000000u128;
//
//         let pool12_key: field = get_pool_key(1u64, 2u64);
//         let pool12: PoolInfo = PoolInfo {
//             id: pool12_key, // hash(token1.id, token2.id)
//             token1_id: 1u64,
//             token2_id: 2u64,
//             reserve1: reserve1,
//             reserve2: reserve2,
//             lp_total_supply: reserve1 * reserve2,
//             swap_fee: 10u128, // 10000 based, 1 = 0.01% = 0.0001
//             tick: 0i32,
//             sqrt_price_x24: 0u64,
//             liquidity: 0u64,
//             t1_protocol_fees: 0u128,
//             t2_protocol_fees: 0u128,
//             tick_spacing: 0u8,
//             max_liq_per_tick: 0u64,
//             feeGrowthGlobal0X32: 0u64,
//             feeGrowthGlobal1X32: 0u64
//         };
//         assert(!Mapping::contains(amm_pools, pool12_key));
//         Mapping::set(amm_pools, pool12_key, pool12);
//
//         let pool13_key: field = get_pool_key(1u64, 3u64);
//         let pool13: PoolInfo = PoolInfo {
//             id: pool13_key,
//             token1_id: 1u64,
//             token2_id: 3u64,
//             reserve1: reserve1,
//             reserve2: reserve3,
//             lp_total_supply: reserve1 * reserve3,
//             swap_fee: 10u128, // 10000 based, 1 = 0.01% = 0.0001
//             tick: 0i32,
//             sqrt_price_x24: 0u64,
//             liquidity: 0u64,
//             t1_protocol_fees: 0u128,
//             t2_protocol_fees: 0u128,
//             tick_spacing: 0u8,
//             max_liq_per_tick: 0u64,
//             feeGrowthGlobal0X32: 0u64,
//             feeGrowthGlobal1X32: 0u64
//         };
//         Mapping::set(amm_pools, pool13_key, pool13);
//
//         let pool14_key: field = get_pool_key(1u64, 4u64);
//         let pool14: PoolInfo = PoolInfo {
//             id: pool14_key,
//             token1_id: 1u64,
//             token2_id: 4u64,
//             reserve1: reserve1,
//             reserve2: reserve4,
//             lp_total_supply: reserve1 * reserve4,
//             swap_fee: 10u128,
//             tick: 0i32,
//             sqrt_price_x24: 0u64,
//             liquidity: 0u64,
//             t1_protocol_fees: 0u128,
//             t2_protocol_fees: 0u128,
//             tick_spacing: 0u8,
//             max_liq_per_tick: 0u64,
//             feeGrowthGlobal0X32: 0u64,
//             feeGrowthGlobal1X32: 0u64
//         };
//         Mapping::set(amm_pools, pool14_key, pool14);
//
//         let pool23_key: field = get_pool_key(2u64, 3u64);
//         let pool23: PoolInfo = PoolInfo {
//             id: pool23_key, // hash(token1.id, token2.id)
//             token1_id: 2u64,
//             token2_id: 3u64,
//             reserve1: reserve2,
//             reserve2: reserve3,
//             lp_total_supply: reserve2 * reserve3,
//             swap_fee: 10u128,
//             tick: 0i32,
//             sqrt_price_x24: 0u64,
//             liquidity: 0u64,
//             t1_protocol_fees: 0u128,
//             t2_protocol_fees: 0u128,
//             tick_spacing: 0u8,
//             max_liq_per_tick: 0u64,
//             feeGrowthGlobal0X32: 0u64,
//             feeGrowthGlobal1X32: 0u64
//             };
//         Mapping::set(amm_pools, pool23_key, pool23);
//
//         let pool24_key: field = get_pool_key(2u64, 4u64);
//         let pool24: PoolInfo = PoolInfo {
//             id: pool24_key,
//             token1_id: 2u64,
//             token2_id: 4u64,
//             reserve1: reserve2,
//             reserve2: reserve4,
//             lp_total_supply: reserve2 * reserve4,
//             swap_fee: 10u128,
//             tick: 0i32,
//             sqrt_price_x24: 0u64,
//             liquidity: 0u64,
//             t1_protocol_fees: 0u128,
//             t2_protocol_fees: 0u128,
//             tick_spacing: 0u8,
//             max_liq_per_tick: 0u64,
//             feeGrowthGlobal0X32: 0u64,
//             feeGrowthGlobal1X32: 0u64
//         };
//         Mapping::set(amm_pools, pool24_key, pool24);
//
//         let pool34_key: field = get_pool_key(3u64, 4u64);
//         let pool34: PoolInfo = PoolInfo {
//             id: pool34_key,
//             token1_id: 3u64,
//             token2_id: 4u64,
//             reserve1: reserve3,
//             reserve2: reserve4,
//             lp_total_supply: reserve3 * reserve4,
//             swap_fee: 10u128,
//             tick: 0i32,
//             sqrt_price_x24: 0u64,
//             liquidity: 0u64,
//             t1_protocol_fees: 0u128,
//             t2_protocol_fees: 0u128,
//             tick_spacing: 0u8,
//             max_liq_per_tick: 0u64,
//             feeGrowthGlobal0X32: 0u64,
//             feeGrowthGlobal1X32: 0u64
//         };
//         Mapping::set(amm_pools, pool34_key, pool34);
//     }

    // transition tmp_get_pool_id() -> (field, field, field, field) {
    //     return (get_pool_key(1u64, 2u64), get_pool_key(1u64, 3u64), get_pool_key(2u64, 3u64), get_pool_key(2u64, 4u64));
    // }

    // transition get_my_address() -> address {
    //     return arcaneutil.leo/get_caller_address();
    // }

    // ██████████████████████████████████████████████████████████████████████
    //                                 LiquidityMath
    // ██████████████████████████████████████████████████████████████████████

    const FP_Q32: u64 = 4294967296u64;
    const Q32_RESOLUTION: u32 = 32u32;

    const FP_Q24: u64 = 16777216u64;
    const Q24_RESOLUTION: u32 = 24u32;

    const U64_MAX: u64 = 18446744073709551615u64;
    const U40_MAX: u64 = 1099511627775u64;

    transition main(dummy: field) -> u64 {
        let c: u64 = lm_add_delta(10u64, -1i64);
        return mul_mod(1u64, 2u64, 123u64);
    }

    inline gt_u64(x: u64, y: u64) -> u64 {
        return x > y ? 1u64 : 0u64;
    }

    inline lt_u64(x: u64, y: u64) -> u64 {
        return x < y ? 1u64 : 0u64;
    }

    inline div_rounding_up(x: u64, y: u64) -> u64 {
        let x_mod_y: u64 = x.mod(y);
        let gt: u64 = gt_u64(x_mod_y, 0u64);
        let x_div_y: u64 = x.div(y);

        return x_div_y + gt;
    }

    inline  mul_mod(a: u64, b: u64, k: u64) -> u64 {
        let a_128: u128 = a as u128;
        let b_128: u128 = b as u128;
        let k_128: u128 = k as u128;

        let product: u128 = a_128.mul(b_128);
        let mod_u128: u128 = product.mod(k_128);
        let mod_u64: u64 = mod_u128 as u64;

        return mod_u64;
    }

    inline mul_div(a: u64, b: u64, k: u64) -> u64 {
        let a_128: u128 = a as u128;
        let b_128: u128 = b as u128;
        let k_128: u128 = k as u128;

        let product: u128 = a_128.mul(b_128);
        let div_128: u128 = product.div(k_128);
        let div_u64: u64 = div_128 as u64;

        return div_u64;
    }

    inline mul_div_rounding_up(
            a: u64,
            b: u64,
            denominator: u64
        ) -> u64 {
            let result: u64 = mul_div(a, b, denominator);
            if (mul_mod(a, b, denominator) > 0u64) {
                assert(result < U64_MAX);
                result = result + 1u64;
            }
            return result;
        }

    inline lm_add_delta(x: u64, y: i64) -> u64 {
        return ((x as i64) + y) as u64;
//      let z: u64 = 0u64; todo assertion 'left right failed: Constant constraint failed: (0 * 1) =?= 1
//
//      if (y < 0i64) {
//          let y_abs: i64 = -y;
//          z = x - (y_abs as u64);
//          assert(z < x);
//      } else {
//          let y_abs: i64 = y;
//          z = x + (y_abs as u64);
//          assert(z >= x);
//      }
//      return z;
    }

    inline min_u128(a: u128, b: u128) -> u128 {
        return a < b ? a : b;
    }

    inline sqrt_u128(a: u128) -> u128 {
        if (a == 0u128) {
            return 0u128;
        }
        let result: u128 = 1u128.shl(log2(a) / 2u32);

        result = (result + a / result) >> 1u32;
        result = (result + a / result) >> 1u32;
        result = (result + a / result) >> 1u32;
        result = (result + a / result) >> 1u32;
        result = (result + a / result) >> 1u32;
        result = (result + a / result) >> 1u32;
        result = (result + a / result) >> 1u32;
        return min_u128(result, a / result);
    }

    inline log2(value: u128) -> u32 {
        let result: u32 = 0u32;
        // if value >> 128u32 > 0u128 {
        //     value >>= 128u32;
        //     result += 12832;
        // }
        if value >> 64u32 > 0u128 {
            value >>= 64u32;
            result += 64u32;
        }
        if value >> 32u32 > 0u128 {
            value >>= 32u32;
            result += 32u32;
        }
        if value >> 16u32 > 0u128 {
            value >>= 16u32;
            result += 16u32;
        }
        if value >> 8u32 > 0u128 {
            value >>= 8u32;
            result += 8u32;
        }
        if value >> 4u32 > 0u128 {
            value >>= 4u32;
            result += 4u32;
        }
        if value >> 2u32 > 0u128 {
            value >>= 2u32;
            result += 2u32;
        }
        if value >> 1u32 > 0u128 {
            result += 1u32;
        }
        return result;
    }
    // ██████████████████████████████████████████████████████████████████████
    //                                 Position
    // ██████████████████████████████████████████████████████████████████████

    struct PositionInfo {
        liquidity: u64,
        feeGrowthInside0LastX32: u64,
        feeGrowthInside1LastX32: u64,
        tokensOwed0: u64,
        tokensOwed1: u64,
    }

    struct PositionInfoKey {
        owned_by: address,
        tick_lower: i32,
        tick_upper: i32,
    }

    inline get_position_info_key(owned_by: address, tick_lower: i32, tick_upper: i32) -> field {
        let position_key: field = BHP256::hash_to_field(PositionInfoKey {owned_by: owned_by, tick_lower: tick_lower, tick_upper: tick_upper});
        return position_key;
    }

    struct EffectUpdateTickInfo {
        is_empty: bool,
        tick_key: field,
        tick_info: TickInfo,
    }

    struct EffectFlipTick {
        is_empty: bool,
        tick: i32,
    }

    struct EffectClearTick {
        is_empty: bool,
        tick: i32,
    }


    inline empty_effect_update_tick() -> EffectUpdateTickInfo {
        return EffectUpdateTickInfo {
            is_empty: true,
            tick_key: 0field,
            tick_info: empty_tick_info(),
        };
    }

    inline effect_update_tick(tick_key: field, tick_info: TickInfo) -> EffectUpdateTickInfo {
        return EffectUpdateTickInfo {
            is_empty: false,
            tick_key: tick_key,
            tick_info: tick_info,
        };
    }

    inline empty_effect_flip_tick() -> EffectFlipTick {
        return EffectFlipTick {
            is_empty: true,
            tick: 0i32
        };
    }

    inline effect_flip_tick(tick: i32) -> EffectFlipTick {
        return EffectFlipTick {
            is_empty: false,
            tick: tick
        };
    }

    inline empty_effect_clear_tick() -> EffectClearTick {
        return EffectClearTick {
            is_empty: true,
            tick: 0i32
        };
    }

    inline effect_clear_tick(tick: i32) -> EffectClearTick {
        return EffectClearTick {
            is_empty: false,
            tick: tick
        };
    }

    inline empty_tick_info() -> TickInfo {
        return TickInfo {
               liquidityGross: 0u64,
               liquidityNet: 0i64,
               feeGrowthOutside0X32: 0u64,
               feeGrowthOutside1X32: 0u64,
               initialized: false
       };
    }

    inline empty_position_info() -> PositionInfo {
        return PositionInfo {
            liquidity: 0u64,
            feeGrowthInside0LastX32: 0u64,
            feeGrowthInside1LastX32: 0u64,
            tokensOwed0: 0u64,
            tokensOwed1: 0u64,
       };
    }

    struct ModifyPositionParams {
        orig_position: PositionInfo,
        tick_lower: i32,
        tick_upper: i32,
        lower_tick_info: TickInfo,
        upper_tick_info: TickInfo,
        liquidity_delta: i64,
        pool_meta: PoolMeta,
        pool_state: PoolState,
    }


    struct ModifyPositionResult {
        update_position_result: UpdatePositionResult,
        token1_amount: i64,
        token2_amount: i64,
        liquidity_after: u64
    }

    inline check_ticks(lower: i32, upper: i32) {
        assert(lower < upper);
        assert(lower >= MIN_TICK);
        assert(upper <= MAX_TICK);
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    /// @return amount2 the amount of token2 owed to the pool, negative if the pool should pay the recipient
    inline modify_position(params: ModifyPositionParams) -> ModifyPositionResult {
        check_ticks(params.tick_lower, params.tick_upper);

        let token1_amount: i64 = 0i64;
        let token2_amount: i64 = 0i64;
        let liquidity_after: u64 = params.pool_state.liquidity;

        let update_position_result: UpdatePositionResult = update_position(
            params.orig_position,
            params.tick_lower,
            params.tick_upper,
            params.liquidity_delta,
            params.lower_tick_info,
            params.upper_tick_info,
            params.pool_meta,
            params.pool_state
        );

        if (params.liquidity_delta != 0i64) {
            if (params.pool_state.tick < params.tick_lower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                token1_amount = getAmount0Delta(
                    getSqrtRatioAtTick(params.tick_lower),
                    getSqrtRatioAtTick(params.tick_upper),
                    params.liquidity_delta
                );
            } else if (params.pool_state.tick < params.tick_upper) {
                // current tick is inside the passed range
                let liquidity_before: u64 = params.pool_state.liquidity;

                token1_amount = getAmount0Delta(
                    params.pool_state.sqrt_price_x24,
                    getSqrtRatioAtTick(params.tick_upper),
                    params.liquidity_delta
                );
                token2_amount = getAmount1Delta(
                    getSqrtRatioAtTick(params.tick_lower),
                    params.pool_state.sqrt_price_x24,
                    params.liquidity_delta
                );

                liquidity_after = lm_add_delta(liquidity_before, params.liquidity_delta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                token2_amount = getAmount1Delta(
                    getSqrtRatioAtTick(params.tick_lower),
                    getSqrtRatioAtTick(params.tick_upper),
                    params.liquidity_delta
                );
            }
        }

        return ModifyPositionResult {
               update_position_result: update_position_result,
               token1_amount: token1_amount,
               token2_amount: token2_amount,
               liquidity_after: liquidity_after
        };
    }

    struct UpdatePositionResult {
        modified_position: PositionInfo,
        effect_update_lower_tick: EffectUpdateTickInfo,
        effect_update_upper_tick: EffectUpdateTickInfo,
        effect_flip_lower_tick: EffectFlipTick,
        effect_flip_upper_tick: EffectFlipTick,
        effect_clear_lower_tick: EffectClearTick,
        effect_clear_upper_tick: EffectClearTick
    }

    inline update_position(
        orig_position: PositionInfo,
        tick_lower: i32,
        tick_upper: i32,
        liquidity_delta: i64,
        lower_tick_info: TickInfo,
        upper_tick_info: TickInfo,
        pool_meta: PoolMeta,
        pool_state: PoolState,
    ) -> UpdatePositionResult {
        let tick: i32 = pool_state.tick; // current tick

        // result items start
        let flipped_lower: bool = false;
        let flipped_upper: bool = false;

        let effect_update_lower_tick: EffectUpdateTickInfo = empty_effect_update_tick();
        let effect_update_upper_tick: EffectUpdateTickInfo = empty_effect_update_tick();

        let effect_flip_lower_tick: EffectFlipTick = empty_effect_flip_tick();
        let effect_flip_upper_tick: EffectFlipTick = empty_effect_flip_tick();

        let new_lower_tick_info: TickInfo = lower_tick_info;
        let new_upper_tick_info: TickInfo = upper_tick_info;

        let effect_clear_lower_tick: EffectClearTick = empty_effect_clear_tick();
        let effect_clear_upper_tick: EffectClearTick = empty_effect_clear_tick();
        // result items end

        let fee_growth_global0_X32: u64 = pool_state.feeGrowthGlobal0X32;
        let fee_growth_global1_X32: u64 = pool_state.feeGrowthGlobal1X32;

        if (liquidity_delta != 0i64) {
            let lower_res: (TickInfo, bool) = ticks_update(
                lower_tick_info,
                tick_lower,
                tick,
                liquidity_delta,
                fee_growth_global0_X32,
                fee_growth_global1_X32,
                false, // is upper
                pool_meta.max_liq_per_tick // maxLiquidity
            );
            new_lower_tick_info = lower_res.0;
            flipped_lower = lower_res.1;

            effect_update_lower_tick = effect_update_tick(0field, new_lower_tick_info);

            let upper_res: (TickInfo, bool) = ticks_update(
                upper_tick_info,
                tick_upper,
                tick,
                liquidity_delta,
                fee_growth_global0_X32,
                fee_growth_global1_X32,
                true, // is upper
                pool_meta.max_liq_per_tick // maxLiquidity
            );
            new_upper_tick_info = upper_res.0;
            flipped_upper = upper_res.1;

            effect_update_upper_tick = effect_update_tick(0field, new_upper_tick_info);

            if (flipped_lower) {
                effect_flip_lower_tick = effect_flip_tick(tick_lower);
            }
            if (flipped_upper) {
                effect_flip_upper_tick = effect_flip_tick(tick_upper);
            }
        }

        let fee_growth_inside: (u64, u64) = getFeeGrowthInside(
            new_lower_tick_info, // lower: TickInfo,
            new_upper_tick_info, // upper: TickInfo,
            tick_lower, // tickLower: i32,
            tick_upper, // tickUpper: i32,
            tick, // tickCurrent: i32,
            fee_growth_global0_X32, // feeGrowthGlobal0X32: u64,
            fee_growth_global1_X32 // feeGrowthGlobal1X32: u64
        );

        let feeGrowthInside0X32: u64 = fee_growth_inside.0;
        let feeGrowthInside1X32: u64 = fee_growth_inside.1;

        let modified_position: PositionInfo = position_update(
            orig_position,
            liquidity_delta,
            feeGrowthInside0X32,
            feeGrowthInside1X32
        );

        // clear any tick data that is no longer needed
        if (liquidity_delta < 0i64) {
            if (flipped_lower) {
                effect_clear_lower_tick = effect_clear_tick(tick_lower);
            }
            if (flipped_upper) {
                effect_clear_upper_tick = effect_clear_tick(tick_upper);
            }
        }
        return UpdatePositionResult {
                modified_position: modified_position,
                effect_update_lower_tick: effect_update_lower_tick,
                effect_update_upper_tick: effect_update_upper_tick,
                effect_flip_lower_tick: effect_flip_lower_tick,
                effect_flip_upper_tick: effect_flip_upper_tick,
                effect_clear_lower_tick: effect_clear_lower_tick,
                effect_clear_upper_tick: effect_clear_upper_tick
        };
    }

    inline position_update(
         positionInfo: PositionInfo,
         liquidityDelta: i64,
         feeGrowthInside0X32: u64,
         feeGrowthInside1X32: u64
         ) -> PositionInfo {
             let liquidityNext: u64 = 0u64;
             if (liquidityDelta == 0i64) {
                 assert(positionInfo.liquidity > 0u64); // disallow pokes for 0 liquidity positions
                 liquidityNext = positionInfo.liquidity;
             } else {
                 let liq_i64: u64 = positionInfo.liquidity;
                 let ld: u64 =  lm_add_delta(liq_i64, liquidityDelta);
                 liquidityNext = ld;
             }
             let tokensOwed0: u64 =
                     mul_div(
                         feeGrowthInside0X32 - positionInfo.feeGrowthInside0LastX32,
                         positionInfo.liquidity,
                         FP_Q32
                     );
             let tokensOwed1: u64 =
                     mul_div(
                         feeGrowthInside1X32 - positionInfo.feeGrowthInside1LastX32,
                         positionInfo.liquidity,
                         FP_Q32
                 );
             return PositionInfo {
                liquidity: liquidityNext,
                feeGrowthInside0LastX32: feeGrowthInside0X32,
                feeGrowthInside1LastX32: feeGrowthInside1X32,
                tokensOwed0: positionInfo.tokensOwed0 + tokensOwed0,
                tokensOwed1: positionInfo.tokensOwed1 + tokensOwed1,
             };
    }

    // ██████████████████████████████████████████████████████████████████████
    //                                 SqrtPriceMath
    // ██████████████████████████████████████████████████████████████████████


    inline getNextSqrtPriceFromAmount0RoundingUp(
        sqrtPX24: u64,
        liquidity: u64,
        amount: u64,
        add: bool
    ) -> u64 {
        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input price
        if (amount == 0u64) {
            return sqrtPX24;
        }
        let numerator1: u64 = liquidity.shl(Q24_RESOLUTION);

        if (add) {
            let product: u64 = (amount * sqrtPX24) / amount;
            if (product == sqrtPX24) {
                let denominator: u64 = numerator1 + product as u64;
                if (denominator >= numerator1) {
                    return mul_div_rounding_up(numerator1, sqrtPX24, denominator);
                }
            }
            return div_rounding_up(numerator1, (numerator1 / sqrtPX24).add(amount));
        } else {
            let product: u64 = amount * sqrtPX24;
            // if the product overflows, we know the denominator underflows
            // in addition, we must check that the denominator does not underflow
            assert((product / amount) == sqrtPX24);
            assert(numerator1 > product);
            let denominator: u64 = numerator1 - product as u64;
            return mul_div_rounding_up(numerator1, sqrtPX24, denominator);
        }
    }

    inline getNextSqrtPriceFromAmount1RoundingDown(
            sqrtPX24: u64,
            liquidity: u64,
            amount: u64,
            add: bool
        ) -> u64 {
            // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
            // in both cases, avoid a mulDiv for most inputs
            if (add) {
                let quotient: u64 =
                    (
                        amount <= U40_MAX
                            ? amount.shl(Q24_RESOLUTION) / liquidity
                            : mul_div(amount, FP_Q24, liquidity)
                    );
                return sqrtPX24 + quotient;
            } else {
                let quotient: u64 =
                    (
                        amount <= U40_MAX
                            ? div_rounding_up(amount.shl(Q24_RESOLUTION), liquidity)
                            : mul_div_rounding_up(amount, FP_Q24, liquidity)
                    );

                assert(sqrtPX24 > quotient);

                // always fit 40 bits (64 - 24)
                return sqrtPX24 - quotient;
            }
        }

        inline getNextSqrtPriceFromInput(
                sqrtPX24: u64,
                liquidity: u64,
                amountIn: u64,
                zeroForOne: bool
            ) -> u64 {
                assert(sqrtPX24 > 0u64);
                assert(liquidity > 0u64);

                // round to make sure that we don't pass the target price
                return zeroForOne
                        ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX24, liquidity, amountIn, true)
                        : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX24, liquidity, amountIn, true);
        }

        inline getNextSqrtPriceFromOutput(
                sqrtPX24: u64,
                liquidity: u64,
                amountOut: u64,
                zeroForOne: bool
            ) -> u64 {
                assert(sqrtPX24 > 0u64);
                assert(liquidity > 0u64);

                // round to make sure that we pass the target price
                return zeroForOne
                        ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX24, liquidity, amountOut, false)
                        : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX24, liquidity, amountOut, false);
            }

        inline getAmount0Delta_roundUp(
                sqrtRatioAX24: u64,
                sqrtRatioBX24: u64,
                liquidity: u64,
                roundUp: bool
            ) -> u64 {
                if (sqrtRatioAX24 > sqrtRatioBX24) {
                    let tmp: u64 = sqrtRatioBX24;
                    sqrtRatioBX24 = sqrtRatioAX24;
                    sqrtRatioAX24 = tmp;
                }

                let numerator1: u64 = liquidity.shl(Q24_RESOLUTION);
                let numerator2: u64 = sqrtRatioBX24 - sqrtRatioAX24;

                assert(sqrtRatioAX24 > 0u64);

                return
                    roundUp
                        ? div_rounding_up(
                            mul_div_rounding_up(numerator1, numerator2, sqrtRatioBX24),
                            sqrtRatioAX24
                        )
                        : mul_div(numerator1, numerator2, sqrtRatioBX24) / sqrtRatioAX24;
            }

        inline getAmount1Delta_roundUp(
                sqrtRatioAX24: u64,
                sqrtRatioBX24: u64,
                liquidity: u64,
                roundUp: bool
            ) -> u64 {
                if (sqrtRatioAX24 > sqrtRatioBX24) {
                    let tmp: u64 = sqrtRatioBX24;
                    sqrtRatioBX24 = sqrtRatioAX24;
                    sqrtRatioAX24 = tmp;
                }

                return roundUp ? mul_div_rounding_up(liquidity, sqrtRatioBX24 - sqrtRatioAX24, FP_Q24)
                        : mul_div(liquidity, sqrtRatioBX24 - sqrtRatioAX24, FP_Q24);
            }

       inline getAmount0Delta(
              sqrtRatioAX24: u64,
              sqrtRatioBX24: u64,
              liquidity: i64
          ) -> i64 {
              return liquidity < 0i64
                      ? -1i64 * getAmount0Delta_roundUp(sqrtRatioAX24, sqrtRatioBX24, -liquidity as u64, false) as i64
                      : getAmount0Delta_roundUp(sqrtRatioAX24, sqrtRatioBX24, liquidity as u64, true) as i64;
          }

       inline getAmount1Delta(
               sqrtRatioAX24: u64,
               sqrtRatioBX24: u64,
               liquidity: i64
           ) -> i64 {
               return
                   liquidity < 0i64
                       ? -1i64 * getAmount1Delta_roundUp(sqrtRatioAX24, sqrtRatioBX24, -liquidity as u64, false) as i64
                       : getAmount1Delta_roundUp(sqrtRatioAX24, sqrtRatioBX24, liquidity as u64, true) as i64;
           }


       // ██████████████████████████████████████████████████████████████████████
       //                                 Ticks
       // ██████████████████████████████████████████████████████████████████████

       mapping initialized_ticks: i32 => bool;

    // info stored for each initialized individual tick
    struct TickInfo {
        // the total position liquidity that references this tick
        liquidityGross: u64,
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        liquidityNet: i64,
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        feeGrowthOutside0X32: u64,
        feeGrowthOutside1X32: u64,
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        initialized: bool
    }

    inline getFeeGrowthInside(
            lower: TickInfo,
            upper: TickInfo,
            tickLower: i32,
            tickUpper: i32,
            tickCurrent: i32,
            feeGrowthGlobal0X32: u64,
            feeGrowthGlobal1X32: u64
        ) -> (u64, u64)  {
            // calculate fee growth below
            let feeGrowthBelow0X32: u64 = 0u64;
            let feeGrowthBelow1X32: u64 = 0u64;
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X32 = lower.feeGrowthOutside0X32;
                feeGrowthBelow1X32 = lower.feeGrowthOutside1X32;
            } else {
                feeGrowthBelow0X32 = feeGrowthGlobal0X32 - lower.feeGrowthOutside0X32;
                feeGrowthBelow1X32 = feeGrowthGlobal1X32 - lower.feeGrowthOutside1X32;
            }

            // calculate fee growth above
            let feeGrowthAbove0X32: u64 = 0u64;
            let feeGrowthAbove1X32: u64 = 0u64;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X32 = upper.feeGrowthOutside0X32;
                feeGrowthAbove1X32 = upper.feeGrowthOutside1X32;
            } else {
                feeGrowthAbove0X32 = feeGrowthGlobal0X32 - upper.feeGrowthOutside0X32;
                feeGrowthAbove1X32 = feeGrowthGlobal1X32 - upper.feeGrowthOutside1X32;
            }

            let feeGrowthInside0X32: u64 = feeGrowthGlobal0X32 - feeGrowthBelow0X32 - feeGrowthAbove0X32;
            let feeGrowthInside1X32: u64 = feeGrowthGlobal1X32 - feeGrowthBelow1X32 - feeGrowthAbove1X32;

            return (feeGrowthInside0X32, feeGrowthInside1X32);
        }

 /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param time The current block timestamp cast to a uint32
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    inline ticks_update(
        info: TickInfo,
        tick: i32,
        tickCurrent: i32,
        liquidityDelta: i64,
        feeGrowthGlobal0X32: u64,
        feeGrowthGlobal1X32: u64,
        upper: bool,
        maxLiquidity: u64
    ) -> (TickInfo, bool) {
        let liquidityGrossBefore: u64 = info.liquidityGross;
        let liquidityGrossAfter: u64 = lm_add_delta(liquidityGrossBefore, liquidityDelta);

        assert(liquidityGrossAfter <= (maxLiquidity));

        let flipped: bool = ((liquidityGrossAfter == 0u64) != (liquidityGrossBefore == 0u64));

         let info_feeGrowthOutside0X32: u64 = info.feeGrowthOutside0X32;
         let info_feeGrowthOutside1X32: u64 = info.feeGrowthOutside1X32;
         let info_initialized: bool = info.initialized;

        if (liquidityGrossBefore == 0u64) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= tickCurrent) {
                info_feeGrowthOutside0X32 = feeGrowthGlobal0X32;
                info_feeGrowthOutside1X32 = feeGrowthGlobal1X32;
            }
            info_initialized = true;
        }

        let info_liquidityGross: u64 = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        let info_liquidityNet: i64 = upper ? info.liquidityNet.sub(liquidityDelta) : info.liquidityNet.add(liquidityDelta);

        let updated_info: TickInfo = TickInfo {
                                           liquidityGross: info_liquidityGross,
                                           liquidityNet: info_liquidityNet,
                                           feeGrowthOutside0X32: info_feeGrowthOutside0X32,
                                           feeGrowthOutside1X32: info_feeGrowthOutside1X32,
                                           initialized: info_initialized
                                   };
        return (updated_info, flipped);
    }

        /// @notice Transitions to next tick as needed by price movement
        /// @param self The mapping containing all tick information for initialized ticks
        /// @param tick The destination tick of the transition
        /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
        /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
        /// @param time The current block.timestamp
        /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
        inline cross(
            info: TickInfo,
            feeGrowthGlobal0X32: u64,
            feeGrowthGlobal1X32: u64
        ) -> TickInfo {
            let updated_info: TickInfo = TickInfo {
                                liquidityGross: info.liquidityGross,
                                liquidityNet: info.liquidityNet,
                                feeGrowthOutside0X32: feeGrowthGlobal0X32 - info.feeGrowthOutside0X32,
                                feeGrowthOutside1X32: feeGrowthGlobal1X32 - info.feeGrowthOutside1X32,
                                initialized: info.initialized
            };
            return updated_info;
        }

       // ██████████████████████████████████████████████████████████████████████
       //                                 Tick Math
       // ██████████████████████████████████████████████████████████████████████

    inline getSqrtRatioAtTick(tick: i32) -> u64 {
        return tick.abs() as u64; // todo
    }

    struct ComputeSwapStepResult {
        sqrtRatioNextX96: u64,
        amountIn: u64,
        amountOut: u64,
        feeAmount: u64
    }
/// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    inline computeSwapStep(
        sqrtRatioCurrentX96: u64,
        sqrtRatioTargetX96: u64,
        liquidity: u64,
        amountRemaining: i64,
        feePips: u64
    ) -> ComputeSwapStepResult {
        let sqrtRatioNextX96: u64 = 0u64;
        let amountIn: u64 = 0u64;
        let amountOut: u64 = 0u64;
        let feeAmount: u64 = 0u64;

        let zeroForOne: bool = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        let exactIn: bool = amountRemaining >= 0i64;

        if (exactIn) {
            let amountRemainingLessFee: u64 = mul_div(amountRemaining as u64, 1000000u64 - feePips, 1000000u64);
            amountIn = zeroForOne
                ? getAmount0Delta_roundUp(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : getAmount1Delta_roundUp(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            if (amountRemainingLessFee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
            }
        } else {
            amountOut = zeroForOne
                ? getAmount1Delta_roundUp(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : getAmount0Delta_roundUp(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (((-amountRemaining) as u64) >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    ((-amountRemaining) as u64),
                    zeroForOne
                );
            }
        }

        let max: bool = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        if (zeroForOne) {
            amountIn = (max && exactIn)
                ? amountIn
                : getAmount0Delta_roundUp(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = (max && !exactIn)
                ? amountOut
                : getAmount1Delta_roundUp(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = (max && exactIn)
                ? amountIn
                : getAmount1Delta_roundUp(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = (max && !exactIn)
                ? amountOut
                : getAmount0Delta_roundUp(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exactIn && amountOut > ((-amountRemaining) as u64)) {
            amountOut = ((-amountRemaining) as u64);
        }

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = (amountRemaining as u64) - amountIn;
        } else {
            feeAmount = mul_div_rounding_up(amountIn, feePips, 1000000u64 - feePips);
        }

        return ComputeSwapStepResult {
                sqrtRatioNextX96: sqrtRatioNextX96,
                amountIn: amountIn,
                amountOut: amountOut,
                feeAmount: feeAmount
        };
    }

}