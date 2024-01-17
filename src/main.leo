import arcanetoken.leo;
import arcaneutil.leo;

program arcane_amm_v3_3.aleo {

    const SELF_ADDRESS: address = aleo1pvndtzpeujjk6387wpxw4z4fz5qeq866rhcecz9hqnf0dmsrt5gqgsl0a4;

    // NOTE ticks fragmentation
    const MIN_TICK: u32 = 1u32;
    const MAX_TICK: u32 = 24u32;

    transition get_program_address() -> address {
        return arcaneutil.leo/get_caller_address();
    }

    transition get_pool_key_transition(id1: u64, id2: u64) -> field {
        return get_pool_key(id1, id2);
    }

    transition get_position_key(owner: address, tick_lower: u32, tick_upper: u32) -> field {
        return get_position_info_key(owner, tick_lower, tick_upper);
    }

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
        tick: u32
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
        swap_fee: u128, // 10000 based, 1 = 0.01% = 0.0001
        protocol_fee: u128, // 0,4,5,6,7,8,9,10 => 0, 1/4, 1/5, 1/6, 1/7, 1/8, 1/9, or 1/10
        tick_prices: [u128; 24], // sqrt_price_x32 for tick i = tick_prices[i]
        tick_price_ranges: [u128; 25], // lower sqrt_price_x32 = tick_price_ranges[i], upper sqrt_price_x32 = tick_price_ranges[i + 1]
        max_liq_per_tick: u128 // sqrt(amount_x * amount_y)
    }

    // mutable pool data
    struct PoolState {
        tick: u32,
        sqrt_price_x32: u128,
        liquidity: u128,
        t1_protocol_fees: u128,
        t2_protocol_fees: u128,
        fee_growth_global_1: u128,
        fee_growth_global_2: u128,
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
        token_amount: u128,
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

    inline get_pool_tick_key(token1: u64, token2: u64, tick: u32) -> field {
        let actual_token1: u64 = token1 > token2 ? token2 : token1;
        let actual_token2: u64 = token1 <= token2 ? token2 : token1;
        return BHP256::hash_to_field(PoolTickKey {token1: actual_token1, token2: actual_token2, tick: tick});
    }

    transition create_pool(
        owner: address,
        token1_id: u64,
        token2_id: u64,
        tick_prices: [u128; 24], // sqrt_price_x32 for tick i = tick_prices[i]
        tick_price_ranges: [u128; 25], // lower sqrt_price_x32 = tick_price_ranges[i], upper sqrt_price_x32 = tick_price_ranges[i + 1]
        max_liq_per_tick: u128,
        tick: u32,
        swap_fee: u128, // 10000 based, 1 = 0.01% = 0.0001,
        protocol_fee: u128, // 0,4,5,6,7,8,9,10 => 0, 1/4, 1/5, 1/6, 1/7, 1/8, 1/9, or 1/10
        ) -> (PoolAdmin) {
        assert(token1_id < token2_id);
        assert(swap_fee <= 10000u128);
        assert(protocol_fee >= 0u128);
        assert(protocol_fee <= 10u128);

        let pool_key: field = get_pool_key(token1_id, token2_id);

        let pool_admin: PoolAdmin = PoolAdmin {
            owner: owner,
            pool_key: pool_key
        };

        return (pool_admin) then finalize(pool_key, token1_id, token2_id, tick_prices, tick_price_ranges, max_liq_per_tick, tick, swap_fee, protocol_fee);
    }

    finalize create_pool(
            pool_key: field,
            token1_id: u64,
            token2_id: u64,
            tick_prices: [u128; 24],
            tick_price_ranges: [u128; 25],
            max_liq_per_tick: u128,
            tick: u32,
            swap_fee: u128,
            protocol_fee: u128) {
        assert(!Mapping::contains(map_pool_meta, pool_key)); // the pool already exists
        assert(!Mapping::contains(map_pool_state, pool_key)); // the pool already exists

        let pool_meta: PoolMeta = PoolMeta {
            id: pool_key, // hash(token1.id, token2.id)
            token1_id: token1_id,
            token2_id: token2_id,
            tick_prices: tick_prices,
            tick_price_ranges: tick_price_ranges,
            swap_fee: swap_fee,
            protocol_fee: protocol_fee,
            max_liq_per_tick: max_liq_per_tick
        };

        let sqrt_price_x32: u128 = get_price_by_tick(tick, tick_prices);

        let pool_state: PoolState = PoolState {
            tick: tick,
            sqrt_price_x32: sqrt_price_x32,
            liquidity: 0u128,
            t1_protocol_fees: 0u128,
            t2_protocol_fees: 0u128,
            fee_growth_global_1: 0u128,
            fee_growth_global_2: 0u128
        };
        Mapping::set(map_pool_meta, pool_key, pool_meta);
        Mapping::set(map_pool_state, pool_key, pool_state);
    }

    transition transfer_pool_ownership(poolAdmin: PoolAdmin, to: address) -> (PoolAdmin) {
        assert(poolAdmin.owner == self.caller);
        return PoolAdmin {
            owner: to,
            pool_key: poolAdmin.pool_key
        };
    }

    transition create_position(owner: address,
                               tick_lower: u32,
                               tick_upper: u32,
                               liquidity: u64, // sqrt (amount1 * amount2)
                               token1: arcanetoken.leo/ArcaneToken,
                               token1_amount: u128,
                               extra_voucher_1: field,
                               token2: arcanetoken.leo/ArcaneToken,
                               token2_amount: u128,
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

        return (token1_change_record, token2_change_record, position_receipt, extra_amount_voucher_1, extra_amount_voucher_2) then finalize(position_id, tick_lower, tick_upper, liquidity, token1.token_id, token1_amount, token2.token_id, token2_amount, extra_voucher_1, extra_voucher_2);
    }

    finalize create_position(
        position_id: field,
        tick_lower: u32,
        tick_upper: u32,
        liquidity: u64,
        token1_id: u64,
        token1_amount: u128,
        token2_id: u64,
        token2_amount: u128,
        extra_amount_voucher_1: field,
        extra_amount_voucher_2: field) {
//         assert(!Mapping::contains(map_position, position_id));

        let pool_key: field = get_pool_key(token1_id, token2_id);
        let pool_meta: PoolMeta = Mapping::get(map_pool_meta, pool_key);
        let pool_state: PoolState = Mapping::get(map_pool_state, pool_key);

//         assert(pool_meta.token1_id == token1_id);
//         assert(pool_meta.token2_id == token2_id);

        let empty_tick_lower_info: TickInfo = empty_tick_info();
        let lower_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_lower);
        let lower_tick_info: TickInfo = Mapping::get_or_use(map_tick_info, lower_tick_key, empty_tick_lower_info);

        let empty_tick_upper_info: TickInfo = empty_tick_info();
        let upper_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_upper);
        let upper_tick_info: TickInfo = Mapping::get_or_use(map_tick_info, upper_tick_key, empty_tick_upper_info);

        let liquidity_delta: i64 = liquidity as i64;

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

        let token1_amount_actual: u128 = result.token1_amount.abs() as u128;
        let token2_amount_actual: u128 = result.token2_amount.abs() as u128;
//         if (token1_amount == 0u128) {
//             assert(token1_amount_actual == 0u128);
//         }
//         if (token2_amount == 0u128) {
//             assert(token2_amount_actual == 0u128);
//         }
//         assert(token1_amount_actual <= token1_amount);
//         assert(token2_amount_actual <= token2_amount);

        let extra_change_1: u128 = token1_amount - token1_amount_actual;
        let extra_amount_1: ExtraAmount = ExtraAmount {
            token_id: token1_id,
            token_amount: extra_change_1,
        };
        Mapping::set(map_extra_voucher, extra_amount_voucher_1, extra_amount_1);

        let extra_change_2: u128 = token2_amount - token2_amount_actual;
        let extra_amount_2: ExtraAmount = ExtraAmount {
            token_id: token2_id,
            token_amount: extra_change_2,
        };
        Mapping::set(map_extra_voucher, extra_amount_voucher_2, extra_amount_2);

        let effects: UpdatePositionResult = result.update_position_result;
        Mapping::set(map_position, position_id, effects.modified_position);

        let lower_tick_info_modified: TickInfo = effects.effect_update_lower_tick.is_empty ? lower_tick_info : effects.effect_update_lower_tick.tick_info;
        Mapping::set(map_tick_info, effects.effect_update_lower_tick.tick_key, lower_tick_info_modified);

        let upper_tick_info_modified: TickInfo = effects.effect_update_upper_tick.is_empty ? upper_tick_info : effects.effect_update_upper_tick.tick_info;
        Mapping::set(map_tick_info, effects.effect_update_upper_tick.tick_key, upper_tick_info_modified);

        let lower_inited: bool = Mapping::get_or_use(map_tick_initialized, lower_tick_key, false);
        let lower_flipped: bool = !effects.effect_flip_lower_tick.is_empty;
        let lower_modified: bool = lower_flipped ? !lower_inited : lower_inited;
        Mapping::set(map_tick_initialized, lower_tick_key, lower_modified);

        let upper_inited: bool = Mapping::get_or_use(map_tick_initialized, upper_tick_key, false);
        let upper_flipped: bool = !effects.effect_flip_upper_tick.is_empty;
        let upper_modified: bool = upper_flipped ? !upper_inited : upper_inited;
        Mapping::set(map_tick_initialized, upper_tick_key, upper_modified);

        let liquidity_after: u128 = result.liquidity_after;
        Mapping::set(map_pool_state, pool_key, PoolState {
             tick: pool_state.tick,
             sqrt_price_x32: pool_state.sqrt_price_x32,
             liquidity: liquidity_after,
             t1_protocol_fees: pool_state.t1_protocol_fees,
             t2_protocol_fees: pool_state.t2_protocol_fees,
             fee_growth_global_1: pool_state.fee_growth_global_1,
             fee_growth_global_2: pool_state.fee_growth_global_2
        });
    }

    transition test_modify_position() -> i64 {
            let tick_prices: [u128; 24] = [3593427452u128,4085866296u128,4108378126u128,4130767274u128,4153035722u128,4175185403u128,4197218197u128,4219135934u128,4240940399u128,4262633331u128,4284216422u128,4305691326u128,4327059652u128,4348322973u128,4369482820u128,4390540691u128,4411498045u128,4432356308u128,4453116872u128,4473781099u128,4494350316u128,4514825822u128,4535208886u128,4915814758u128];
            let tick_price_ranges: [u128; 25] = [3037000500u128,4074563739u128,4097137672u128,4119587910u128,4141916463u128,4164125290u128,4186216295u128,4208191335u128,4230052216u128,4251800700u128,4273438502u128,4294967296u128,4316388712u128,4337704342u128,4358915736u128,4380024411u128,4401031842u128,4421939475u128,4442748717u128,4463460944u128,4484077502u128,4504599703u128,4525028831u128,4545366142u128,5260239169u128];

            let pool_meta: PoolMeta = PoolMeta {
                id: 4192939143489893958183065211448386508130081772115300972806275416853025311330field,
                token1_id: 1u64,
                token2_id: 2u64,
                tick_prices: tick_prices,
                tick_price_ranges: tick_price_ranges,
                swap_fee: 100u128,
                protocol_fee: 4u128,
                max_liq_per_tick: U32_MAX
            };

            let sqrt_price_x32: u128 = get_price_by_tick(8u32, tick_prices);

            let pool_state: PoolState = PoolState {
                tick: 8u32,
                sqrt_price_x32: sqrt_price_x32,
                liquidity: 0u128,
                t1_protocol_fees: 0u128,
                t2_protocol_fees: 0u128,
                fee_growth_global_1: 0u128,
                fee_growth_global_2: 0u128
            };
            let params: ModifyPositionParams = ModifyPositionParams {
                    orig_position: empty_position_info(),
                    tick_lower: 8u32,
                    tick_upper: 14u32,
                    lower_tick_info: empty_tick_info(),
                    upper_tick_info: empty_tick_info(),
                    liquidity_delta: 10000000i64,
                    pool_meta: pool_meta,
                    pool_state: pool_state,
            };
            let result: ModifyPositionResult = modify_position(params);

        return result.token1_amount;
    }

    transition close_position(receiver: address,
                              tick_lower: u32,
                              tick_upper: u32,
                              position_receipt: PositionReceipt,
                              token1: arcanetoken.leo/ArcaneToken,
                              token1_amount: u128,
                              extra_voucher_1: field,
                              token2: arcanetoken.leo/ArcaneToken,
                              token2_amount: u128,
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
        tick_lower: u32,
        tick_upper: u32,
        token1_id: u64,
        token1_amount: u128,
        token2_id: u64,
        token2_amount: u128,
        extra_amount_voucher_1: field,
        extra_amount_voucher_2: field) {
        assert(Mapping::contains(map_position, position_id));
    
        let position_info: PositionInfo = Mapping::get(map_position, position_id);

        let pool_key: field = get_pool_key(token1_id, token2_id);
        let pool_meta: PoolMeta = Mapping::get(map_pool_meta, pool_key);
        let pool_state: PoolState = Mapping::get(map_pool_state, pool_key);

        assert(pool_meta.token1_id == token1_id);
        assert(pool_meta.token2_id == token2_id);

        let empty_lower_tick_info: TickInfo = empty_tick_info();
        let lower_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_lower);
        let lower_tick_info: TickInfo = Mapping::get_or_use(map_tick_info, lower_tick_key, empty_lower_tick_info);

        let empty_upper_tick_info: TickInfo = empty_tick_info();
        let upper_tick_key: field = get_pool_tick_key(token1_id, token2_id, tick_upper);
        let upper_tick_info: TickInfo = Mapping::get_or_use(map_tick_info, upper_tick_key, empty_upper_tick_info);

        let liquidity_delta: i64 = 0i64;
        if (token1_amount != 0u128 && token2_amount != 0u128) {
            liquidity_delta = ((token1_amount * token2_amount) as i64).neg();
        } else if (token1_amount == 0u128) {
            liquidity_delta = (token2_amount as i64).neg();
        } else {
            liquidity_delta = (token1_amount as i64).neg();
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

        let token1_amount_actual: u128 = result.token1_amount.abs() as u128;
        let token2_amount_actual: u128 = result.token2_amount.abs() as u128;
        if (token1_amount == 0u128) {
            assert(token1_amount_actual == 0u128);
        }
        if (token2_amount == 0u128) {
            assert(token2_amount_actual == 0u128);
        }
        assert(token1_amount_actual >= token1_amount);
        assert(token2_amount_actual >= token2_amount);

        let extra_change_1: u128 = token1_amount_actual - token1_amount;
        let extra_amount_1: ExtraAmount = ExtraAmount {
            token_id: token1_id,
            token_amount: extra_change_1
        };
        Mapping::set(map_extra_voucher, extra_amount_voucher_1, extra_amount_1);

        let extra_change_2: u128 = token2_amount_actual - token2_amount;
        let extra_amount_2: ExtraAmount = ExtraAmount {
            token_id: token2_id,
            token_amount: extra_change_2
        };
        Mapping::set(map_extra_voucher, extra_amount_voucher_2, extra_amount_2);

        let effects: UpdatePositionResult = result.update_position_result;
        Mapping::set(map_position, position_id, effects.modified_position);

        let lower_tick_info_modified: TickInfo = effects.effect_update_lower_tick.is_empty ? lower_tick_info : effects.effect_update_lower_tick.tick_info;
        Mapping::set(map_tick_info, effects.effect_update_lower_tick.tick_key, lower_tick_info_modified);

        let upper_tick_info_modified: TickInfo = effects.effect_update_upper_tick.is_empty ? upper_tick_info : effects.effect_update_upper_tick.tick_info;
        Mapping::set(map_tick_info, effects.effect_update_upper_tick.tick_key, upper_tick_info_modified);

        let lower_inited: bool = Mapping::get_or_use(map_tick_initialized, lower_tick_key, false);
        let lower_flipped: bool = !effects.effect_flip_lower_tick.is_empty;
        let lower_modified: bool = lower_flipped ? !lower_inited : lower_inited;
        Mapping::set(map_tick_initialized, lower_tick_key, lower_modified);

        let upper_inited: bool = Mapping::get_or_use(map_tick_initialized, upper_tick_key, false);
        let upper_flipped: bool = !effects.effect_flip_upper_tick.is_empty;
        let upper_modified: bool = upper_flipped ? !upper_inited : upper_inited;
        Mapping::set(map_tick_initialized, upper_tick_key, upper_modified);

        let liquidity_after: u128 = result.liquidity_after;
        Mapping::set(map_pool_state, pool_key, PoolState {
             tick: pool_state.tick,
             sqrt_price_x32: pool_state.sqrt_price_x32,
             liquidity: liquidity_after,
             t1_protocol_fees: pool_state.t1_protocol_fees,
             t2_protocol_fees: pool_state.t2_protocol_fees,
             fee_growth_global_1: pool_state.fee_growth_global_1,
             fee_growth_global_2: pool_state.fee_growth_global_2
        });
    }


    transition swap(exact_input: bool, receiver: address, token_in: arcanetoken.leo/ArcaneToken, amount_in: u128, token_out_id: u64, amount_out: u128, price_limit: u128, extra_voucher_in: field, extra_voucher_out: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher, ExtraAmountVoucher) {
        assert(amount_out > 0u128);

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

        return (change, token_out, extra_amount_voucher_in, extra_amount_voucher_out) then finalize(exact_input, token_in.token_id, amount_in, token_out_id, amount_out, price_limit, extra_voucher_in, extra_voucher_out);
    }

    finalize swap(exact_input: bool, token_in_id: u64, amount_in: u128, token_out_id: u64, amount_out: u128, price_limit: u128, extra_change_voucher_in: field, extra_change_voucher_out: field) {
        let pool_key: field = get_pool_key(token_in_id, token_out_id);
        let pool_meta: PoolMeta = Mapping::get(map_pool_meta, pool_key);
        let pool_state: PoolState = Mapping::get(map_pool_state, pool_key);

        let zeroForOne: bool = token_in_id > token_out_id;
        let amountSpecified: u128 = amount_in;

        assert(
            zeroForOne
                ? price_limit < pool_state.sqrt_price_x32 // && price_limit > TickMath.MIN_SQRT_RATIO todo MIN/MAX sqrt ratio
                : price_limit > pool_state.sqrt_price_x32 // && price_limit < TickMath.MAX_SQRT_RATIO
        );

        // liquidity at the beginning of the swap
        let liquidityStart: u128 = pool_state.liquidity;
        let swap_fee: u128 = pool_meta.swap_fee;
        let protocol_fee: u128 = pool_meta.protocol_fee;

        let state_amountSpecifiedRemaining: i64 = amountSpecified as i64;
        let state_amountCalculated: i64 = 0i64;
        let state_price: u128 = pool_state.sqrt_price_x32;
        let state_tick: u32 = pool_state.tick;
        let state_fee_growth_global: u128 = zeroForOne ? pool_state.fee_growth_global_1 : pool_state.fee_growth_global_2;
        let state_protocolFee: u128 = 0u128;
        let state_liquidity: u128 = liquidityStart;

        // NOTE ticks fragmentation:
        // max 16 writes per finalize (https://github.com/AleoHQ/snarkVM/issues/2248) = update pool_state + voucher t1 + voucher t2 + ticks info updates
        // assume that one swap will not shift price more than 3 ticks left or right
        for i: u32 in 0u32..3u32 {
            // continue swapping as long as we haven't used the entire input/output and haven't reached the sqrt_price_x32 limit
            let finished: bool = (state_amountSpecifiedRemaining == 0i64 || state_price == price_limit || state_tick > MAX_TICK || state_tick < MIN_TICK);
            let step_price_start: u128 = state_price;
            let step_tickNext: u32 = 0u32;
            let step_initialized: bool = false;
            let step_price_next: u128 = 0u128;
            let step_amountIn: u128 = 0u128;
            let step_amountOut: u128 = 0u128;
            let step_feeAmount: u128 = 0u128;

            let tick_to_check: u32 = state_tick;
            let found_initialized_tick: bool = false;

            tick_to_check = zeroForOne ? tick_to_check - 1u32 : tick_to_check + 1u32;

            let pool_tick_key: field = get_pool_tick_key(pool_meta.token1_id, pool_meta.token2_id, tick_to_check);
            let tick_initialized: bool = Mapping::get_or_use(map_tick_initialized, pool_tick_key, false);
            if (tick_initialized && !found_initialized_tick) {
                found_initialized_tick = true;
                step_tickNext = tick_to_check;
                step_initialized = true;
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

            // get the sqrt_price_x32 for the next tick
            step_price_next = get_price_by_tick(step_tickNext, pool_meta.tick_prices);

            // compute values to swap to the target tick, sqrt_price_x32 limit, or point where input/output amount is exhausted

            let empty_swap_step: ComputeSwapStepResult = ComputeSwapStepResult {
                price_next: state_price,
                amountIn: 0u128,
                amountOut: 0u128,
                feeAmount: 0u128
            };
            let swap_step_result: ComputeSwapStepResult = finished ? empty_swap_step : computeSwapStep(
                state_price,
                (zeroForOne ? step_price_next < price_limit : step_price_next > price_limit)
                    ? price_limit
                    : step_price_next,
                state_liquidity,
                state_amountSpecifiedRemaining,
                pool_meta.swap_fee
            );
            state_price = swap_step_result.price_next;
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
            if (protocol_fee > 0u128) {
                let delta: u128 = step_feeAmount / protocol_fee; // delta goes to protocol
                step_feeAmount = step_feeAmount - delta;
                state_protocolFee = state_protocolFee + delta;
            }

            // update global fee tracker
            if (state_liquidity > 0u128) {
               state_fee_growth_global = state_fee_growth_global + mul_div(step_feeAmount, FP_Q32, state_liquidity);
            }

            let pool_tick_next_key: field = get_pool_tick_key(pool_meta.token1_id, pool_meta.token2_id, step_tickNext);
            let next_tick_info_prev: TickInfo = Mapping::get(map_tick_info, pool_tick_next_key);
            let updated_next_tick_info: TickInfo = next_tick_info_prev;

            // shift tick if we reached the next sqrt_price_x32
            if (state_price == step_price_next) {
                // if the tick is initialized, run the tick transition
                if (step_initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick

                    updated_next_tick_info = cross(
                            next_tick_info_prev,
                            (zeroForOne ? state_fee_growth_global : pool_state.fee_growth_global_1),
                            (zeroForOne ? pool_state.fee_growth_global_2 : state_fee_growth_global)
                        );
                    let liquidityNet: i64 = updated_next_tick_info.liquidityNet;

                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (zeroForOne) {
                       liquidityNet = liquidityNet.neg();
                    }
                    state_liquidity = lm_add_delta(state_liquidity, liquidityNet);
                }
                state_tick = zeroForOne ? step_tickNext - 1u32 : step_tickNext;
            } else if (state_price != step_price_start) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state_tick = get_tick_by_price(state_price, pool_meta.tick_price_ranges);
            }
            Mapping::set(map_tick_info, pool_tick_next_key, updated_next_tick_info);
        }

        let pool_state_price: u128 = pool_state.sqrt_price_x32;
        let pool_state_tick: u32 = pool_state.tick;
        let pool_state_liquidity: u128 = pool_state.liquidity;
        let pool_state_fee_growth_global_1: u128 = pool_state.fee_growth_global_1;
        let pool_state_fee_growth_global_2: u128 = pool_state.fee_growth_global_2;
        let pool_state_t1_protocol_fees: u128 = pool_state.t1_protocol_fees;
        let pool_state_t2_protocol_fees: u128 = pool_state.t2_protocol_fees;

        // update tick and write an oracle entry if the tick change
        if (state_tick != pool_state.tick) {
            pool_state_price = state_price;
            pool_state_tick = state_tick;
        } else {
            // otherwise just update the sqrt_price_x32
            pool_state_price = state_price;
        }

        // update liquidity if it changed
        if (liquidityStart != state_liquidity) {
            pool_state_liquidity = state_liquidity;
        }

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        if (zeroForOne) {
            pool_state_fee_growth_global_1 = state_fee_growth_global;
            if (state_protocolFee > 0u128) {
                 pool_state_t1_protocol_fees = pool_state_t1_protocol_fees + state_protocolFee;
            }
        } else {
            pool_state_fee_growth_global_2 = state_fee_growth_global;
            if (state_protocolFee > 0u128) {
                pool_state_t2_protocol_fees = pool_state_t2_protocol_fees + state_protocolFee;
            }
        }

        let updated_pool_state: PoolState = PoolState {
                    tick: pool_state_tick,
                    sqrt_price_x32: pool_state_price,
                    liquidity: pool_state_liquidity,
                    t1_protocol_fees: pool_state_t1_protocol_fees,
                    t2_protocol_fees: pool_state_t2_protocol_fees,
                    fee_growth_global_1: pool_state_fee_growth_global_1,
                    fee_growth_global_2: pool_state_fee_growth_global_2
                };
        Mapping::set(map_pool_state, pool_key, updated_pool_state);

        let amount1: i64 = (zeroForOne == exact_input) ? ((amountSpecified as i64) - state_amountSpecifiedRemaining) : state_amountCalculated;
        let amount2: i64 = (zeroForOne == exact_input) ? state_amountCalculated : ((amountSpecified as i64) - state_amountSpecifiedRemaining);

        let extra_change_out: u128 = 0u128;
        let extra_change_in: u128 = 0u128;
        if (zeroForOne) {
            // amount1 is amount_in
            // amount2 amount_out
            if (amount2 < 0i64) {
                let amount2_abs: u128 = amount2.abs() as u128;
                assert(amount_out <= amount2_abs);
                extra_change_out = amount2_abs - amount_out;
            }
            let amount1_abs: u128 = amount1.abs() as u128;
            assert(amount1_abs <= amount_in);
            extra_change_in = amount_in - amount1_abs;
        } else {
            // amount1 is amount_out
            // amount2 is amount_in
            if (amount1 < 0i64) {
                let amount1_abs: u128 = amount1.abs() as u128;
                assert(amount_out <= amount1_abs);
                extra_change_out = amount1_abs - amount_out;
            }
            let amount2_abs: u128 = amount2.abs() as u128;
            assert(amount2_abs <= amount_in);
            extra_change_in = amount_in - amount2_abs;
        }

        let extra_amount_out: ExtraAmount = ExtraAmount {
                            token_id: token_out_id,
                            token_amount: extra_change_out
                            };
        Mapping::set(map_extra_voucher, extra_change_voucher_out, extra_amount_out);

        let extra_amount_in: ExtraAmount = ExtraAmount {
            token_id: token_in_id,
            token_amount: extra_change_in
        };
        Mapping::set(map_extra_voucher, extra_change_voucher_in, extra_amount_in);
    }

    transition redeem_voucher(voucher: ExtraAmountVoucher, amount: u128) -> (arcanetoken.leo/ArcaneToken) {
        let token: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(voucher.token_id, voucher.owner, amount);
        return token then finalize(voucher.token_id, voucher.voucher, amount);
    }

    finalize redeem_voucher(token_id: u64, voucher_code: field, amount: u128) {
        let extra: ExtraAmount = Mapping::get(map_extra_voucher, voucher_code);
        assert (extra.token_id == token_id && extra.token_amount == amount);
        Mapping::remove(map_extra_voucher, voucher_code);
    }


    // ██████████████████████████████████████████████████████████████████████
    //                                 LiquidityMath
    // ██████████████████████████████████████████████████████████████████████

    const FP_Q32: u128 = 4294967296u128;
    const Q32_RESOLUTION: u32 = 32u32;

    const U32_MAX: u128 = 4294967296u128;

    transition main(dummy: field) -> u128 {
        let c: u128 = lm_add_delta(10u128, -1i64);
        return mul_mod(1u128, 2u128, 123u128);
    }

    inline gt_u128(x: u128, y: u128) -> u128 {
        return x > y ? 1u128 : 0u128;
    }

    inline lt_u128(x: u128, y: u128) -> u128 {
        return x < y ? 1u128 : 0u128;
    }

    inline div_rounding_up(x: u128, y: u128) -> u128 {
        let x_mod_y: u128 = x.mod(y);
        let gt: u128 = gt_u128(x_mod_y, 0u128);
        let x_div_y: u128 = x.div(y);

        return x_div_y + gt;
    }

    inline mul_mod(a: u128, b: u128, k: u128) -> u128 {
        // TODO EVM has built-in mulmod instruction,
        // but Aleo doesn't have one, so we will catch overflow if a*b > MAX_U128
        let product: u128 = a.mul(b);
        let mod: u128 = product.mod(k);
        return mod;
    }

    inline mul_div(a: u128, b: u128, k: u128) -> u128 {
        // TODO EVM has built-in mulmod instruction,
        // but Aleo doesn't have one, so we will catch overflow if a*b > MAX_U128
        let product: u128 = a.mul(b);
        let div: u128 = product.div(k);
        return div;
    }

    inline mul_div_rounding_up(
            a: u128,
            b: u128,
            denominator: u128
        ) -> u128 {
            let has_mod: bool = mul_mod(a, b, denominator) > 0u128;
            let result: u128 = has_mod ? mul_div(a, b, denominator) + 1u128 : mul_div(a, b, denominator);
            return result;
        }

    inline lm_add_delta(x: u128, y: i64) -> u128 {
        return ((x as i128) + y as i128) as u128;
    }

    inline min_u128(a: u128, b: u128) -> u128 {
        return a < b ? a : b;
    }

    // ██████████████████████████████████████████████████████████████████████
    //                                 Position
    // ██████████████████████████████████████████████████████████████████████

    struct PositionInfo {
        liquidity: u128,
        fee_growth_inside_1_last: u128,
        fee_growth_inside_2_last: u128,
        tokensOwed0: u128,
        tokensOwed1: u128,
    }

    struct PositionInfoKey {
        owned_by: address,
        tick_lower: u32,
        tick_upper: u32,
    }

    inline get_position_info_key(owned_by: address, tick_lower: u32, tick_upper: u32) -> field {
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
        tick: u32,
    }

    struct EffectClearTick {
        is_empty: bool,
        tick: u32,
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
            tick: 0u32
        };
    }

    inline effect_flip_tick(tick: u32) -> EffectFlipTick {
        return EffectFlipTick {
            is_empty: false,
            tick: tick
        };
    }

    inline empty_effect_clear_tick() -> EffectClearTick {
        return EffectClearTick {
            is_empty: true,
            tick: 0u32
        };
    }

    inline effect_clear_tick(tick: u32) -> EffectClearTick {
        return EffectClearTick {
            is_empty: false,
            tick: tick
        };
    }

    inline empty_tick_info() -> TickInfo {
        return TickInfo {
               liquidityGross: 0u128,
               liquidityNet: 0i64,
               fee_growth_outside_1: 0u128,
               fee_growth_outside_2: 0u128,
               initialized: false
       };
    }

    inline empty_position_info() -> PositionInfo {
        return PositionInfo {
            liquidity: 0u128,
            fee_growth_inside_1_last: 0u128,
            fee_growth_inside_2_last: 0u128,
            tokensOwed0: 0u128,
            tokensOwed1: 0u128,
       };
    }

    struct ModifyPositionParams {
        orig_position: PositionInfo,
        tick_lower: u32,
        tick_upper: u32,
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
        liquidity_after: u128
    }

    inline check_ticks(lower: u32, upper: u32) {
//         assert(lower < upper);
//         assert(lower >= MIN_TICK);
//         assert(upper <= MAX_TICK);
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    /// @return amount2 the amount of token2 owed to the pool, negative if the pool should pay the recipient
    inline modify_position(params: ModifyPositionParams) -> ModifyPositionResult {
        check_ticks(params.tick_lower, params.tick_upper);

        let liquidity_after: u128 = params.pool_state.liquidity;

        let update_position_result: UpdatePositionResult = update_position(
            params.orig_position,
            params.tick_lower,
            params.tick_upper,
            params.liquidity_delta,
            params.lower_tick_info,
            params.upper_tick_info,
            params.pool_meta.max_liq_per_tick,
            params.pool_state.tick,
            params.pool_state.fee_growth_global_1,
            params.pool_state.fee_growth_global_2,
        );

        let current_below: bool = params.pool_state.tick < params.tick_lower;
        let current_above: bool = params.pool_state.tick > params.tick_upper;
        let current_inside: bool = !current_below && !current_above;

        let token1_amount: i64 = current_above ? 0i64 : ( current_below ? getAmount0Delta(
            get_price_by_tick(params.tick_lower, params.pool_meta.tick_prices),
            get_price_by_tick(params.tick_upper, params.pool_meta.tick_prices),
            params.liquidity_delta
        ) : getAmount0Delta(
               params.pool_state.sqrt_price_x32,
               get_price_by_tick(params.tick_upper, params.pool_meta.tick_prices),
               params.liquidity_delta
        ));

        let token2_amount: i64 = current_below ? 0i64 : (current_above ? getAmount1Delta(
           get_price_by_tick(params.tick_lower, params.pool_meta.tick_prices),
           get_price_by_tick(params.tick_upper, params.pool_meta.tick_prices),
           params.liquidity_delta) :
           getAmount1Delta(
             get_price_by_tick(params.tick_lower, params.pool_meta.tick_prices),
             params.pool_state.sqrt_price_x32,
             params.liquidity_delta
                           )
           );

        let liquidity_before: u128 = params.pool_state.liquidity;
        liquidity_after = current_inside ? lm_add_delta(liquidity_before, params.liquidity_delta) : params.pool_state.liquidity;

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
        tick_lower: u32,
        tick_upper: u32,
        liquidity_delta: i64,
        lower_tick_info: TickInfo,
        upper_tick_info: TickInfo,
        max_liq_per_tick: u128,
        pool_state_tick: u32,
        pool_state_fee_growth_global_1: u128,
        pool_state_fee_growth_global_2: u128
    ) -> UpdatePositionResult {
        let tick: u32 = pool_state_tick; // current tick

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

        let fee_growth_global_1: u128 = pool_state_fee_growth_global_1;
        let fee_growth_global_2: u128 = pool_state_fee_growth_global_2;

        let lower_res: (TickInfo, bool) = ticks_update(
            lower_tick_info,
            tick_lower,
            tick,
            liquidity_delta,
            fee_growth_global_1,
            fee_growth_global_2,
            false, // is upper
            max_liq_per_tick
        );
        new_lower_tick_info = lower_res.0;
        flipped_lower = lower_res.1;

        effect_update_lower_tick = effect_update_tick(0field, new_lower_tick_info);

        let upper_res: (TickInfo, bool) = ticks_update(
            upper_tick_info,
            tick_upper,
            tick,
            liquidity_delta,
            fee_growth_global_1,
            fee_growth_global_2,
            true, // is upper
            max_liq_per_tick
        );
        new_upper_tick_info = upper_res.0;
        flipped_upper = upper_res.1;

        effect_update_upper_tick = effect_update_tick(0field, new_upper_tick_info);

        effect_flip_lower_tick = flipped_lower ? effect_flip_tick(tick_lower) : empty_effect_flip_tick();
        effect_flip_upper_tick = flipped_upper ? effect_flip_tick(tick_upper) : empty_effect_flip_tick();

        let fee_growth_inside: (u128, u128) = getFeeGrowthInside(
            new_lower_tick_info, // lower: TickInfo,
            new_upper_tick_info, // upper: TickInfo,
            tick_lower, // tickLower: u32,
            tick_upper, // tickUpper: u32,
            tick, // tick_current: u32,
            fee_growth_global_1, // fee_growth_global_1: u128,
            fee_growth_global_2 // fee_growth_global_2: u128
        );

        let fee_growth_inside_1: u128 = fee_growth_inside.0;
        let fee_growth_inside_2: u128 = fee_growth_inside.1;

        let modified_position: PositionInfo = position_update(
            orig_position,
            liquidity_delta,
            fee_growth_inside_1,
            fee_growth_inside_2
        );

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
         liquidity_delta: i64,
         fee_growth_inside_1: u128,
         fee_growth_inside_2: u128
         ) -> PositionInfo {
             let liquidityNext: u128 = 0u128;
             let liq_i64: u128 = positionInfo.liquidity;
             let ld: u128 =  lm_add_delta(liq_i64, liquidity_delta);
             liquidityNext = ld;

             let tokensOwed0: u128 =
                     mul_div(
                         fee_growth_inside_1 - positionInfo.fee_growth_inside_1_last,
                         positionInfo.liquidity,
                         FP_Q32
                     );
             let tokensOwed1: u128 =
                     mul_div(
                         fee_growth_inside_2 - positionInfo.fee_growth_inside_2_last,
                         positionInfo.liquidity,
                         FP_Q32
                 );
             return PositionInfo {
                liquidity: liquidityNext,
                fee_growth_inside_1_last: fee_growth_inside_1,
                fee_growth_inside_2_last: fee_growth_inside_2,
                tokensOwed0: positionInfo.tokensOwed0 + tokensOwed0,
                tokensOwed1: positionInfo.tokensOwed1 + tokensOwed1,
             };
    }

    // ██████████████████████████████████████████████████████████████████████
    //                                 SqrtPriceMath
    // ██████████████████████████████████████████████████████████████████████


    inline getNextSqrtPriceFromAmount0(
        sqrt_price_x32: u128,
        liquidity: u128,
        amount: u128,
        add: bool
    ) -> u128 {
        // we short circuit amount == 0 because the result is otherwise not guaranteed to equal the input sqrt_price_x32
        if (amount == 0u128) {
            return sqrt_price_x32;
        }
        let numerator1: u128 = liquidity.shl(Q32_RESOLUTION);

        if (add) {
            let product: u128 = (amount * sqrt_price_x32) / amount;
            if (product == sqrt_price_x32) {
                let denominator: u128 = numerator1 + product;
                if (denominator >= numerator1) {
                    return mul_div_rounding_up(numerator1, sqrt_price_x32, denominator);
                }
            }
            return div_rounding_up(numerator1, (numerator1 / sqrt_price_x32).add(amount));
        } else {
            let product: u128 = amount * sqrt_price_x32;
            // if the product overflows, we know the denominator underflows
            // in addition, we must check that the denominator does not underflow
            assert((product / amount) == sqrt_price_x32);
            assert(numerator1 > product);
            let denominator: u128 = numerator1 - product;
            return mul_div_rounding_up(numerator1, sqrt_price_x32, denominator);
        }
    }

    inline getNextSqrtPriceFromAmount1RoundingDown(
            sqrt_price_x32: u128,
            liquidity: u128,
            amount: u128,
            add: bool
        ) -> u128 {
            // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
            // in both cases, avoid a mulDiv for most inputs
            if (add) {
                let quotient: u128 =
                    (
                        amount <= U32_MAX
                            ? amount.shl(Q32_RESOLUTION) / liquidity
                            : mul_div(amount, FP_Q32, liquidity)
                    );
                return sqrt_price_x32 + quotient;
            } else {
                let quotient: u128 =
                    (
                        amount <= U32_MAX
                            ? div_rounding_up(amount.shl(Q32_RESOLUTION), liquidity)
                            : mul_div_rounding_up(amount, FP_Q32, liquidity)
                    );

                assert(sqrt_price_x32 > quotient);

                // always fit 64 bits (128 - 64)
                return sqrt_price_x32 - quotient;
            }
        }

        transition test_get_next_price() -> u128 {
            return getNextSqrtPriceFromInput(
                4219135934u128,
                12345678u128,
                1000000u128,
                false
            );
        }

        inline getNextSqrtPriceFromInput(
                sqrt_price_x32: u128,
                liquidity: u128,
                amountIn: u128,
                zeroForOne: bool
            ) -> u128 {
                assert(sqrt_price_x32 > 0u128);
                assert(liquidity > 0u128);

                // round to make sure that we don't pass the target sqrt_price_x32
                return zeroForOne
                        ? getNextSqrtPriceFromAmount0(sqrt_price_x32, liquidity, amountIn, true)
                        : getNextSqrtPriceFromAmount1RoundingDown(sqrt_price_x32, liquidity, amountIn, true);
        }

        inline getNextSqrtPriceFromOutput(
                sqrt_price_x32: u128,
                liquidity: u128,
                amountOut: u128,
                zeroForOne: bool
            ) -> u128 {
                assert(sqrt_price_x32 > 0u128);
                assert(liquidity > 0u128);

                // round to make sure that we pass the target sqrt_price_x32
                return zeroForOne
                        ? getNextSqrtPriceFromAmount1RoundingDown(sqrt_price_x32, liquidity, amountOut, false)
                        : getNextSqrtPriceFromAmount0(sqrt_price_x32, liquidity, amountOut, false);
            }

        inline getAmount0Delta_roundUp(
                price_a: u128,
                price_b: u128,
                liquidity: u128,
                roundUp: bool
            ) -> u128 {
                let reorder: bool = price_a > price_b;
                let tmp_a: u128 = price_a;
                let tmp_b: u128 = price_b;
                price_a = reorder ? tmp_b : price_a;
                price_b = reorder ? tmp_a : price_b;

                let numerator1: u128 = liquidity.shl(Q32_RESOLUTION);
                let numerator2: u128 = price_b - price_a;

//                 assert(price_a > 0u128);

                return
                    roundUp
                        ? div_rounding_up(
                            mul_div_rounding_up(numerator1, numerator2, price_b),
                            price_a
                        )
                        : mul_div(numerator1, numerator2, price_b) / price_a;
            }

        inline getAmount1Delta_roundUp(
                price_a: u128,
                price_b: u128,
                liquidity: u128,
                roundUp: bool
            ) -> u128 {
                let reorder: bool = price_a > price_b;
                let tmp_a: u128 = price_a;
                let tmp_b: u128 = price_b;
                price_a = reorder ? tmp_b : price_a;
                price_b = reorder ? tmp_a : price_b;

                return roundUp ? mul_div_rounding_up(liquidity, price_b - price_a, FP_Q32)
                        : mul_div(liquidity, price_b - price_a, FP_Q32);
            }

       transition test_amount_delta() -> u128 {
            return getAmount0Delta_roundUp(
                            4219135934u128,
                            4284216422u128,
                            10000000000u128,
                            false
                        );
       }

       transition test_amount_delta_1() -> u128 {
            return getAmount1Delta_roundUp(
                            4219135934u128,
                            4284216422u128,
                            10000000000u128,
                            false
                        );
       }

       transition test_get_amount_0_delta() -> i64 {
            return getAmount0Delta(4219135934u128, 4284216422u128, 10000000000i64);
       }

       inline getAmount0Delta(
              price_a: u128,
              price_b: u128,
              liquidity: i64
          ) -> i64 {
              return liquidity < 0i64 ? (getAmount0Delta_roundUp(price_a, price_b, liquidity.abs() as u128, false) as i64).neg()
                : getAmount0Delta_roundUp(price_a, price_b, liquidity.abs() as u128, true) as i64;
          }

       inline getAmount1Delta(
               price_a: u128,
               price_b: u128,
               liquidity: i64
           ) -> i64 {
               return
                   liquidity < 0i64
                       ? (getAmount1Delta_roundUp(price_a, price_b, liquidity.abs() as u128, false) as i64).neg()
                       : getAmount1Delta_roundUp(price_a, price_b, liquidity.abs() as u128, true) as i64;
           }


       // ██████████████████████████████████████████████████████████████████████
       //                                 Ticks
       // ██████████████████████████████████████████████████████████████████████

    // info stored for each initialized individual tick
    struct TickInfo {
        // the total position liquidity that references this tick
        liquidityGross: u128,
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        liquidityNet: i64,
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        fee_growth_outside_1: u128,
        fee_growth_outside_2: u128,
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        initialized: bool
    }

    transition test_get_fee_growth_inside() -> (u128, u128) {
        let lower_tick: TickInfo = ticks_update(
                            empty_tick_info(),
                            8u32,
                            11u32,
                            100000i64,
                            0u128,
                            0u128,
                            false, // is upper
                            112345678u128
                        ).0;

        let upper_tick: TickInfo = ticks_update(
                            empty_tick_info(),
                            14u32,
                            11u32,
                            100000i64,
                            0u128,
                            0u128,
                            true, // is upper
                            112345678u128
                        ).0;

        return getFeeGrowthInside(
            lower_tick,
            upper_tick,
            8u32,
            14u32,
            11u32,
            0u128,
            0u128
        );
    }

    inline getFeeGrowthInside(
            lower: TickInfo,
            upper: TickInfo,
            tickLower: u32,
            tickUpper: u32,
            tick_current: u32,
            fee_growth_global_1: u128,
            fee_growth_global_2: u128
        ) -> (u128, u128)  {
            // calculate fee growth below
            let fee_growth_below_1: u128 = 0u128;
            let fee_growth_below_2: u128 = 0u128;
            let current_gte_lower: bool = tick_current >= tickLower;
                fee_growth_below_1 = current_gte_lower ? lower.fee_growth_outside_1 : fee_growth_global_1 - lower.fee_growth_outside_1;
                fee_growth_below_2 = current_gte_lower ? lower.fee_growth_outside_2 : fee_growth_global_2 - lower.fee_growth_outside_2;

            // calculate fee growth above
            let fee_growth_above_1: u128 = 0u128;
            let fee_growth_above_2: u128 = 0u128;

            let current_lte_upper: bool = tick_current < tickUpper;
            fee_growth_above_1 = current_lte_upper ? upper.fee_growth_outside_1 : fee_growth_global_1 - upper.fee_growth_outside_1;
            fee_growth_above_2 = current_lte_upper ? upper.fee_growth_outside_2 : fee_growth_global_2 - upper.fee_growth_outside_2;

            let fee_growth_inside_1: u128 = fee_growth_global_1 - fee_growth_below_1 - fee_growth_above_1;
            let fee_growth_inside_2: u128 = fee_growth_global_2 - fee_growth_below_2 - fee_growth_above_2;

            return (fee_growth_inside_1, fee_growth_inside_2);
        }

    transition test_ticks_update_lower() -> (TickInfo, bool) {
        let lower_res: (TickInfo, bool) = ticks_update(
                    empty_tick_info(),
                    8u32,
                    11u32,
                    100000i64,
                    0u128,
                    0u128,
                    false, // is upper
                    112345678u128
                );
        return lower_res;
    }

    transition test_ticks_update_upper() -> (TickInfo, bool) {
        let upper_res: (TickInfo, bool) = ticks_update(
                    empty_tick_info(),
                    14u32,
                    11u32,
                    100000i64,
                    0u128,
                    0u128,
                    true, // is upper
                    112345678u128
                );
        return upper_res;
    }

 /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tick_current The current tick
    /// @param liquidity_delta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param fee_growth_global_1 The all-time global fee growth, per unit of liquidity, in token0
    /// @param fee_growth_global_2 The all-time global fee growth, per unit of liquidity, in token1
    /// @param time The current block timestamp cast to a uint32
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param max_liquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    inline ticks_update(
        info: TickInfo,
        tick: u32,
        tick_current: u32,
        liquidity_delta: i64,
        fee_growth_global_1: u128,
        fee_growth_global_2: u128,
        upper: bool,
        max_liquidity: u128
    ) -> (TickInfo, bool) {
        let liquidityGrossBefore: u128 = info.liquidityGross;
        let liquidityGrossAfter: u128 = lm_add_delta(liquidityGrossBefore, liquidity_delta);

//         assert(liquidityGrossAfter <= (max_liquidity));

        let flipped: bool = ((liquidityGrossAfter == 0u128) != (liquidityGrossBefore == 0u128));

         let info_fee_growth_outside_1: u128 = info.fee_growth_outside_1;
         let info_fee_growth_outside_2: u128 = info.fee_growth_outside_2;
         let info_initialized: bool = info.initialized;

        let had_zero_liq: bool = liquidityGrossBefore == 0u128;
        let below_current: bool = tick <= tick_current;

        info_initialized = had_zero_liq ? true : info_initialized;

        info_fee_growth_outside_1 = (had_zero_liq && below_current) ? fee_growth_global_1 : info_fee_growth_outside_1;
        info_fee_growth_outside_2 = (had_zero_liq && below_current) ? fee_growth_global_2 : info_fee_growth_outside_2;

        let info_liquidityGross: u128 = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        let info_liquidityNet: i64 = upper ? info.liquidityNet.sub(liquidity_delta) : info.liquidityNet.add(liquidity_delta);

        let updated_info: TickInfo = TickInfo {
                                           liquidityGross: info_liquidityGross,
                                           liquidityNet: info_liquidityNet,
                                           fee_growth_outside_1: info_fee_growth_outside_1,
                                           fee_growth_outside_2: info_fee_growth_outside_2,
                                           initialized: info_initialized
                                   };
        return (updated_info, flipped);
    }

        /// @notice Transitions to next tick as needed by sqrt_price_x32 movement
        /// @param self The mapping containing all tick information for initialized ticks
        /// @param tick The destination tick of the transition
        /// @param fee_growth_global_1 The all-time global fee growth, per unit of liquidity, in token0
        /// @param fee_growth_global_2 The all-time global fee growth, per unit of liquidity, in token1
        /// @param time The current block.timestamp
        /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
        inline cross(
            info: TickInfo,
            fee_growth_global_1: u128,
            fee_growth_global_2: u128
        ) -> TickInfo {
            let updated_info: TickInfo = TickInfo {
                                liquidityGross: info.liquidityGross,
                                liquidityNet: info.liquidityNet,
                                fee_growth_outside_1: fee_growth_global_1 - info.fee_growth_outside_1,
                                fee_growth_outside_2: fee_growth_global_2 - info.fee_growth_outside_2,
                                initialized: info.initialized
            };
            return updated_info;
        }

       // ██████████████████████████████████████████████████████████████████████
       //                                 Tick Math
       // ██████████████████████████████████████████████████████████████████████

    // NOTE ticks fragmentation
    inline get_tick_by_price(sqrt_price_x32: u128, tick_price_ranges: [u128; 25]) -> u32 {
        if (sqrt_price_x32 >= tick_price_ranges[0u8] && sqrt_price_x32 <= tick_price_ranges[1u8]) {
            return 1u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[1u8] && sqrt_price_x32 <= tick_price_ranges[2u8]) {
            return 2u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[2u8] && sqrt_price_x32 <= tick_price_ranges[3u8]) {
            return 3u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[3u8] && sqrt_price_x32 <= tick_price_ranges[4u8]) {
            return 4u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[4u8] && sqrt_price_x32 <= tick_price_ranges[5u8]) {
            return 5u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[5u8] && sqrt_price_x32 <= tick_price_ranges[6u8]) {
            return 6u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[6u8] && sqrt_price_x32 <= tick_price_ranges[7u8]) {
            return 7u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[7u8] && sqrt_price_x32 <= tick_price_ranges[8u8]) {
            return 8u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[8u8] && sqrt_price_x32 <= tick_price_ranges[9u8]) {
            return 9u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[9u8] && sqrt_price_x32 <= tick_price_ranges[10u8]) {
            return 10u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[10u8] && sqrt_price_x32 <= tick_price_ranges[11u8]) {
            return 11u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[11u8] && sqrt_price_x32 <= tick_price_ranges[12u8]) {
            return 12u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[12u8] && sqrt_price_x32 <= tick_price_ranges[13u8]) {
            return 13u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[13u8] && sqrt_price_x32 <= tick_price_ranges[14u8]) {
            return 14u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[14u8] && sqrt_price_x32 <= tick_price_ranges[15u8]) {
            return 15u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[15u8] && sqrt_price_x32 <= tick_price_ranges[16u8]) {
            return 16u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[16u8] && sqrt_price_x32 <= tick_price_ranges[17u8]) {
            return 17u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[17u8] && sqrt_price_x32 <= tick_price_ranges[18u8]) {
            return 18u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[18u8] && sqrt_price_x32 <= tick_price_ranges[19u8]) {
            return 19u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[19u8] && sqrt_price_x32 <= tick_price_ranges[20u8]) {
            return 20u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[20u8] && sqrt_price_x32 <= tick_price_ranges[21u8]) {
            return 21u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[21u8] && sqrt_price_x32 <= tick_price_ranges[22u8]) {
            return 22u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[22u8] && sqrt_price_x32 <= tick_price_ranges[23u8]) {
            return 23u32;
        } else if (sqrt_price_x32 >= tick_price_ranges[23u8] && sqrt_price_x32 <= tick_price_ranges[24u8]) {
            return 24u32;
        } else {
//             assert(false);
            return 0u32;
        }
    }

    transition test_get_price_by_tick() -> u128 {
        let tick: u32 = 14u32;
        let tick_prices: [u128; 24] = [3593427452u128,4085866296u128,4108378126u128,4130767274u128,4153035722u128,4175185403u128,4197218197u128,4219135934u128,4240940399u128,4262633331u128,4284216422u128,4305691326u128,4327059652u128,4348322973u128,4369482820u128,4390540691u128,4411498045u128,4432356308u128,4453116872u128,4473781099u128,4494350316u128,4514825822u128,4535208886u128,4915814758u128];

        return get_price_by_tick(tick, tick_prices);
    }

    // NOTE ticks fragmentation
    inline get_price_by_tick(tick: u32, tick_prices: [u128; 24]) -> u128 {
        let tick_index: u32 = tick - 1u32;
        if (tick_index == 0u32) {
            return tick_prices[0u8];
        } else if (tick_index == 1u32) {
            return tick_prices[1u8];
        } else if (tick_index == 2u32) {
            return tick_prices[2u8];
        } else if (tick_index == 3u32) {
            return tick_prices[3u8];
        } else if (tick_index == 4u32) {
            return tick_prices[4u8];
        } else if (tick_index == 5u32) {
            return tick_prices[5u8];
        } else if (tick_index == 6u32) {
            return tick_prices[6u8];
        } else if (tick_index == 7u32) {
            return tick_prices[7u8];
        } else if (tick_index == 8u32) {
            return tick_prices[8u8];
        } else if (tick_index == 9u32) {
            return tick_prices[9u8];
        } else if (tick_index == 10u32) {
            return tick_prices[10u8];
        } else if (tick_index == 11u32) {
            return tick_prices[11u8];
        } else if (tick_index == 12u32) {
            return tick_prices[12u8];
        } else if (tick_index == 13u32) {
            return tick_prices[13u8];
        } else if (tick_index == 14u32) {
            return tick_prices[14u8];
        } else if (tick_index == 15u32) {
            return tick_prices[15u8];
        } else if (tick_index == 16u32) {
            return tick_prices[16u8];
        } else if (tick_index == 17u32) {
            return tick_prices[17u8];
        } else if (tick_index == 18u32) {
            return tick_prices[18u8];
        } else if (tick_index == 19u32) {
            return tick_prices[19u8];
        } else if (tick_index == 20u32) {
            return tick_prices[20u8];
        } else if (tick_index == 21u32) {
            return tick_prices[21u8];
        } else if (tick_index == 22u32) {
            return tick_prices[22u8];
        } else if (tick_index == 23u32) {
            return tick_prices[23u8];
        } else {
//             assert(false);
            return 0u128;
        }
    }

    struct ComputeSwapStepResult {
        price_next: u128,
        amountIn: u128,
        amountOut: u128,
        feeAmount: u128
    }

    transition test_compute_swap_step() -> ComputeSwapStepResult {
        return computeSwapStep(4294967296u128, 4401031842u128, 1000000u128, 10000i64, 10u128);
    }

    transition test_compute_swap_step_neg() -> ComputeSwapStepResult {
        return computeSwapStep(4294967296u128, 4401031842u128, 1000000u128, -10000i64, 10u128);
    }

/// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param price_current The current sqrt sqrt_price_x32 of the pool
    /// @param price_target The sqrt_price_x32 that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips based on 10000 (1 = 0.01%)
    /// @return price_next The sqrt_price_x32 after swapping the amount in/out, not to exceed the sqrt_price_x32 target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    inline computeSwapStep(
        price_current: u128,
        price_target: u128,
        liquidity: u128,
        amountRemaining: i64,
        feePips: u128
    ) -> ComputeSwapStepResult {
        let price_next: u128 = 0u128;
        let amountIn: u128 = 0u128;
        let amountOut: u128 = 0u128;
        let feeAmount: u128 = 0u128;

        let zeroForOne: bool = price_current >= price_target;
        let exactIn: bool = amountRemaining >= 0i64;

        if (exactIn) {
            let amountRemainingLessFee: u128 = mul_div(amountRemaining.abs() as u128, 10000u128 - feePips, 10000u128);
            amountIn = zeroForOne
                ? getAmount0Delta_roundUp(price_target, price_current, liquidity, true)
                : getAmount1Delta_roundUp(price_current, price_target, liquidity, true);
            if (amountRemainingLessFee >= amountIn) {
                price_next = price_target;
            } else {
                price_next = getNextSqrtPriceFromInput(
                    price_current,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
            }
        } else {
            amountOut = zeroForOne
                ? getAmount1Delta_roundUp(price_target, price_current, liquidity, false)
                : getAmount0Delta_roundUp(price_current, price_target, liquidity, false);
            if (((amountRemaining.abs()) as u128) >= amountOut) {
                price_next = price_target;
            } else {
                price_next = getNextSqrtPriceFromOutput(
                    price_current,
                    liquidity,
                    ((amountRemaining.abs()) as u128),
                    zeroForOne
                );
            }
        }

        let max: bool = price_target == price_next;

        // get the input/output amounts
        if (zeroForOne) {
            amountIn = (max && exactIn)
                ? amountIn
                : getAmount0Delta_roundUp(price_next, price_current, liquidity, true);
            amountOut = (max && !exactIn)
                ? amountOut
                : getAmount1Delta_roundUp(price_next, price_current, liquidity, false);
        } else {
            amountIn = (max && exactIn)
                ? amountIn
                : getAmount1Delta_roundUp(price_current, price_next, liquidity, true);
            amountOut = (max && !exactIn)
                ? amountOut
                : getAmount0Delta_roundUp(price_current, price_next, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exactIn && amountOut > ((amountRemaining.abs()) as u128)) {
            amountOut = ((amountRemaining.abs()) as u128);
        }

        if (exactIn && price_next != price_target) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            let fee_amount_tmp: i64 = (amountRemaining.abs()) - amountIn as i64;
            feeAmount = fee_amount_tmp < 0i64 ? 0u128 :fee_amount_tmp.abs() as u128;
        } else {
            feeAmount = mul_div_rounding_up(amountIn, feePips, 10000u128 - feePips);
        }

        return ComputeSwapStepResult {
                price_next: price_next,
                amountIn: amountIn,
                amountOut: amountOut,
                feeAmount: feeAmount
        };
    }

}