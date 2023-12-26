import credits.leo;
import arcanetoken.leo;

program arcane_amm_v3_0.aleo {

    const SELF_ADDRESS: address = aleo1hy8w46tflux7zwpeaw8ny7tq6wkzqux40z75a9ah3q9tqa4t758qltkqu7;
    const MAX_U64: u64 = 18446744073709551615u64;

    /// ██████████████████████████████████████████████████████████████████████
    ///                             Private AMM Swaps
    /// ██████████████████████████████████████████████████████████████████████

    ///  Pools
    struct PoolKey {
        token1: u64,
        token2: u64,
    }

    record PoolAdmin {
        owner: address,
        pool_key: field
    }

    struct PoolInfo {
        id: field, // hash(token1.id, token2.id)
        token1_id: u64,
        token2_id: u64,
        reserve1: u128,
        reserve2: u128,
        lp_total_supply: u128,
        swap_fee: u128, // 10000 based, 1 = 0.01% = 0.0001
        tick: i32, // the current tick
        t0_protocol_fees: u128,
        t1_protocol_fees: u128,
        tick_spacing: u8,
        max_liq_per_tick: u64,
        feeGrowthGlobal0X32: u64,
        feeGrowthGlobal1X32: u64
    }

    struct DepositKey {
        holder: address,
        pool_key: field,
        deposit_id: field,
    }

    record LpTokenReceipt {
        owner: address,
        token1_id: u64,
        token2_id: u64,
        deposit_id: field
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

    mapping tick_info_mapping: field => TickInfo; // TickInfo by hash(pool_key+tick_index, tick)
    mapping tick_bitmap_mapping: field => bool; // tick initialized true/false by hash(pool_key+tick_index, tick)
    mapping position_mapping: field => PositionInfo; // all opened positions key TBD

    mapping amm_pools: field => PoolInfo; // PoolInfo by hash(token1.id, token2.id)
    mapping amm_deposits: field => u128; // lp deposit amount by hash(id, pool_key)
    mapping amm_extras: field => ExtraAmount; // extra amount by voucher_id

    inline get_pool_key(token1: u64, token2: u64) -> field {
        let actual_token1: u64 = token1 > token2 ? token2 : token1;
        let actual_token2: u64 = token1 <= token2 ? token2 : token1;
        return BHP256::hash_to_field(PoolKey {token1: actual_token1, token2: actual_token2});
    }

    transition create_pool(owner: address, token1: arcanetoken.leo/ArcaneToken, initial_amount1: u128, token2: arcanetoken.leo/ArcaneToken, initial_amount2: u128, swap_fee: u128, tick_spacing: u8) -> (PoolAdmin, arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken) {
        assert(initial_amount1 > 0u128 && initial_amount2 > 0u128);
        assert(swap_fee <= 10000u128); // 10000 based, 1 = 0.01% = 0.0001
        assert(token1.token_id != token2.token_id);
        assert(token1.amount >= initial_amount1 && token2.amount >= initial_amount2);
        assert(token1.token_id < token2.token_id);

        let change1: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token1, SELF_ADDRESS, initial_amount1);
        let change2: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token2, SELF_ADDRESS, initial_amount2);

        let pool_key: field = get_pool_key(token1.token_id, token2.token_id);
        let pool_admin: PoolAdmin = PoolAdmin {
            owner: owner,
            pool_key: pool_key
        };

        return (pool_admin, change1, change2) then finalize(pool_key, token1.token_id, initial_amount1, token2.token_id, initial_amount2, swap_fee, tick_spacing);
    }

    finalize create_pool(pool_key: field, token1_id: u64, token1_amount: u128, token2_id: u64, token2_amount: u128, swap_fee: u128, tick_spacing: u8) {
        assert (!Mapping::contains(amm_pools, pool_key)); // the pool already exists

        let price: u128 = token2_amount / token1_amount;
        let tick: i32 = get_tick_by_price(price);
        let pool: PoolInfo = PoolInfo {
            id: pool_key, // hash(token1.id, token2.id)
            token1_id: token1_id,
            token2_id: token2_id,
            reserve1: token1_amount,
            reserve2: token2_amount,
            lp_total_supply: token1_amount * token2_amount,
            swap_fee: swap_fee, // 10000 based, 1 = 0.01% = 0.0001,
            tick: tick,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: tick_spacing,
            max_liq_per_tick: get_max_liq_per_tick(tick_spacing),
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };

        Mapping::set(amm_pools, pool_key, pool);
    }

    inline get_max_liq_per_tick(tick_spacing: u8) -> u64 {
        return 1000000000000u64; // todo
    }

    inline get_tick_by_price(price: u128) -> i32 {
        return 0i32; // todo
    }

    inline get_price_by_tick(tick: i32) -> u128 {
        return 0u128; // todo
    }

    transition transfer_pool_ownership(poolAdmin: PoolAdmin, to: address) -> (PoolAdmin) {
        assert(poolAdmin.owner == self.caller);
        return PoolAdmin {
            owner: to,
            pool_key: poolAdmin.pool_key
        };
    }

    // current_tick
    transition add_amm_liquidity(owner: address,
                                tick_lower: i32,
                                tick_upper: i32,
                                token1: arcanetoken.leo/ArcaneToken,
                                token1_amount: u128,
                                min_token1_amount: u128,
                                token2: arcanetoken.leo/ArcaneToken,
                                token2_amount: u128,
                                min_token2_amount: u128,
                                deposit_id: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, LpTokenReceipt) {

        let token1_change_record: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token1, SELF_ADDRESS, token1_amount);
        let token2_change_record: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token2, SELF_ADDRESS, token2_amount);

        let lp_token_receipt: LpTokenReceipt = LpTokenReceipt {
            owner: owner,
            token1_id: token1.token_id,
            token2_id: token2.token_id,
            deposit_id: deposit_id
        };

        return (token1_change_record, token2_change_record, lp_token_receipt) then finalize(deposit_id, token1.token_id, token1_amount, min_token1_amount, token2.token_id, token2_amount, min_token2_amount);
    }

    finalize add_amm_liquidity(deposit_id: field, token1_id: u64, token1_amount: u128, min_token1_amount: u128, token2_id: u64, token2_amount: u128, min_token2_amount: u128) {
        let pool_key: field = get_pool_key(token1_id, token2_id);

        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let new_lp1: u128 = (token1_amount * pool.lp_total_supply) / pool.reserve1;
        let new_lp2: u128 = (token2_amount * pool.lp_total_supply) / pool.reserve2;

        let lp: u128 = min_u128(new_lp1, new_lp2);

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.reserve1 + token1_amount,
            reserve2: pool.reserve2 + token2_amount,
            lp_total_supply: pool.lp_total_supply + lp,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool_key, updated_pool);

        assert(!Mapping::contains(amm_deposits, deposit_id));
        Mapping::set(amm_deposits, deposit_id, lp);
    }

    transition remove_amm_liquidity(receiver: address,
                                    lp_receipt: LpTokenReceipt,
                                    token1_amount: u128,
                                    token2_amount: u128,
                                    extra_voucher1: field,
                                    extra_voucher2: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher, ExtraAmountVoucher) {
        assert(extra_voucher1 != extra_voucher2);

        let token1: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(lp_receipt.token1_id, receiver, token1_amount);
        let token2: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(lp_receipt.token2_id, receiver, token2_amount);

        let extra_amount_voucher1: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: lp_receipt.token1_id,
            voucher: extra_voucher1
        };
        let extra_amount_voucher2: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: lp_receipt.token2_id,
            voucher: extra_voucher2
        };

        return (token1, token2, extra_amount_voucher1, extra_amount_voucher2) then finalize(lp_receipt.deposit_id,
                lp_receipt.token1_id, lp_receipt.token2_id, token1_amount, token2_amount, extra_voucher1, extra_voucher2);
    }

    finalize remove_amm_liquidity(deposit_id: field, token1_id: u64, token2_id: u64, token1_amount: u128, token2_amount: u128, extra_voucher1: field, extra_voucher2: field) {
        let pool_key: field = get_pool_key(token1_id, token2_id);
        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let total: u128 = pool.lp_total_supply;

        let deposit_amount_lp: u128 = Mapping::get(amm_deposits, deposit_id);

        let deposit_amount_1: u128 = deposit_amount_lp * pool.reserve1 / total;
        let deposit_amount_2: u128 = deposit_amount_lp * pool.reserve2 / total;

        // automatic underflow check ensures a user didn't request more than they have on this deposit
        let change1: u128 = deposit_amount_1 - token1_amount;
        let change2: u128 = deposit_amount_2 - token2_amount;

        assert (!Mapping::contains(amm_extras, extra_voucher1)); // check if voucher1 is already in use
        Mapping::set(amm_extras, extra_voucher1, ExtraAmount {
            token_id: token1_id,
            token_amount: change1
        });

        assert (!Mapping::contains(amm_extras, extra_voucher2)); // check if voucher2 is already in use
        Mapping::set(amm_extras, extra_voucher2, ExtraAmount {
            token_id: token2_id,
            token_amount: change2
        });

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.reserve1 - deposit_amount_1,
            reserve2: pool.reserve2 - deposit_amount_2,
            lp_total_supply: pool.lp_total_supply - deposit_amount_lp,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool_key, updated_pool);
        Mapping::remove(amm_deposits, deposit_id);
    }

    transition swap_amm(receiver: address, token_in: arcanetoken.leo/ArcaneToken, amount_in: u128, token_out_id: u64, amount_out: u128, extra_voucher: field) -> (arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher) {
        assert(amount_out > 0u128);

        let change: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token_in, SELF_ADDRESS, amount_in);
        let token_out: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(token_out_id, receiver, amount_out);

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token_out_id,
            voucher: extra_voucher
        };

        return (change, token_out, extra_amount_voucher) then finalize(token_in.token_id, amount_in, token_out_id, amount_out, extra_voucher);
    }

    finalize swap_amm(token_in_id: u64, amount_in: u128, token_out_id: u64, amount_out: u128, extra_change_voucher: field) {
        let pool_key: field = get_pool_key(token_in_id, token_out_id);
        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let total: u128 = pool.lp_total_supply;

        let reserve_in: u128 = pool.token1_id == token_in_id ? pool.reserve1 : pool.reserve2;
        let reserve_out: u128 = pool.token2_id == token_in_id ? pool.reserve1 : pool.reserve2;

        let fee: u128 = pool.swap_fee;

        let amount_in_with_fee: u128 = amount_in * (10000u128 - fee);
        let actual_amount_out: u128 = amount_in_with_fee * reserve_out / (reserve_in * 10000u128 + amount_in_with_fee);
        assert(actual_amount_out >= amount_out);

        // Return change
        let extra_change: u128 = actual_amount_out - amount_out;

        let extra_amount: ExtraAmount = ExtraAmount {
            token_id: token_out_id,
            token_amount: extra_change,
        };
        Mapping::set(amm_extras, extra_change_voucher, extra_amount);

        // Update pool
        let reserve_in_new: u128 = reserve_in + amount_in;
        let reserve_out_new: u128 = reserve_out - actual_amount_out;

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            reserve1: pool.token1_id == token_in_id ? reserve_in_new : reserve_out_new,
            reserve2: pool.token2_id == token_in_id ? reserve_in_new : reserve_out_new,
            lp_total_supply: pool.lp_total_supply,
            swap_fee: pool.swap_fee,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };

        Mapping::set(amm_pools, pool_key, updated_pool);
    }

    transition redeem_voucher(voucher: ExtraAmountVoucher, amount: u128) -> (arcanetoken.leo/ArcaneToken) {
        let token: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(voucher.token_id, voucher.owner, amount);
        return token then finalize(voucher.token_id, voucher.voucher, amount);
    }

    finalize redeem_voucher(token_id: u64, voucher_code: field, amount: u128) {
        let extra: ExtraAmount = Mapping::get(amm_extras, voucher_code);
        assert (extra.token_id == token_id && extra.token_amount == amount);
        Mapping::remove(amm_extras, voucher_code);
    }

    /// ██████████████████████████████████████████████████████████████████████
    ///                             CREDITS
    /// ██████████████████████████████████████████████████████████████████████

    transition create_pool_pric(owner: address, token1: credits.leo/credits, initial_amount1: u64, token2: arcanetoken.leo/ArcaneToken, initial_amount2: u128, swap_fee: u128) -> (PoolAdmin, credits.leo/credits, arcanetoken.leo/ArcaneToken) {
        assert(initial_amount1 > 0u64 && initial_amount2 > 0u128);
        assert(swap_fee <= 10000u128); // 10000 based, 1 = 0.01% = 0.0001
        assert(token1.microcredits >= initial_amount1 && token2.amount >= initial_amount2);

        let change1: credits = credits.leo/transfer_private_to_public(token1, SELF_ADDRESS, initial_amount1);
        let change2: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token2, SELF_ADDRESS, initial_amount2);

        let pool_key: field = get_pool_key(0u64, token2.token_id);
        let pool_admin: PoolAdmin = PoolAdmin {
            owner: owner,
            pool_key: pool_key
        };

        return (pool_admin, change1, change2) then finalize(pool_key, 0u64, initial_amount1 as u128, token2.token_id, initial_amount2, swap_fee);
    }

    finalize create_pool_pric(pool_key: field, token1_id: u64, token1_amount: u128, token2_id: u64, token2_amount: u128, swap_fee: u128) {
        assert (!Mapping::contains(amm_pools, pool_key)); // the pool already exists

        let pool: PoolInfo = PoolInfo {
            id: pool_key, // hash(token1.id, token2.id)
            token1_id: token1_id,
            token2_id: token2_id,
            reserve1: token1_amount,
            reserve2: token2_amount,
            lp_total_supply: token1_amount * token2_amount,
            swap_fee: swap_fee, // 10000 based, 1 = 0.01% = 0.0001
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };

        Mapping::set(amm_pools, pool_key, pool);
    }

    transition add_amm_liquidity_pric(
                                owner: address,
                                token1: credits.leo/credits,
                                token1_amount: u64,
                                token2: arcanetoken.leo/ArcaneToken,
                                token2_amount: u128,
                                deposit_id: field) -> (credits.leo/credits, arcanetoken.leo/ArcaneToken, LpTokenReceipt) {
        let token1_change_record: credits = credits.leo/transfer_private_to_public(token1, SELF_ADDRESS, token1_amount);
        let token2_change_record: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token2, SELF_ADDRESS, token2_amount);

        let lp_token_receipt: LpTokenReceipt = LpTokenReceipt {
            owner: owner,
            token1_id: 0u64,
            token2_id: token2.token_id,
            deposit_id: deposit_id
        };

        return (token1_change_record, token2_change_record, lp_token_receipt) then finalize(deposit_id, token1_amount as u128, token2.token_id, token2_amount);
    }

    finalize add_amm_liquidity_pric(deposit_id: field, token1_amount: u128, token2_id: u64, token2_amount: u128) {
        let token1_id: u64 = 0u64;
        let pool_key: field = get_pool_key(token1_id, token2_id);

        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let new_lp1: u128 = (token1_amount * pool.lp_total_supply) / pool.reserve1;
        let new_lp2: u128 = (token2_amount * pool.lp_total_supply) / pool.reserve2;

        let lp: u128 = min_u128(new_lp1, new_lp2);

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.reserve1 + token1_amount,
            reserve2: pool.reserve2 + token2_amount,
            lp_total_supply: pool.lp_total_supply + lp,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool_key, updated_pool);

        assert(!Mapping::contains(amm_deposits, deposit_id));
        Mapping::set(amm_deposits, deposit_id, lp);
    }

    transition remove_amm_liquidity_pric(receiver: address,
                                    lp_receipt: LpTokenReceipt,
                                    token1_amount: u64,
                                    token2_amount: u128,
                                    extra_voucher1: field,
                                    extra_voucher2: field) -> (credits.leo/credits, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher, ExtraAmountVoucher) {
        assert(extra_voucher1 != extra_voucher2);

        let token1: credits = credits.leo/transfer_public_to_private(receiver, token1_amount);
        let token2: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(lp_receipt.token2_id, receiver, token2_amount);

        let extra_amount_voucher1: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: lp_receipt.token1_id,
            voucher: extra_voucher1
        };
        let extra_amount_voucher2: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: lp_receipt.token2_id,
            voucher: extra_voucher2
        };

        return (token1, token2, extra_amount_voucher1, extra_amount_voucher2) then finalize(lp_receipt.deposit_id,
                lp_receipt.token1_id, lp_receipt.token2_id, token1_amount as u128, token2_amount, extra_voucher1, extra_voucher2);
    }

    finalize remove_amm_liquidity_pric(deposit_id: field, token1_id: u64, token2_id: u64, token1_amount: u128, token2_amount: u128, extra_voucher1: field, extra_voucher2: field) {
        let pool_key: field = get_pool_key(token1_id, token2_id);
        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let total: u128 = pool.lp_total_supply;

        let deposit_amount_lp: u128 = Mapping::get(amm_deposits, deposit_id);

        let deposit_amount_1: u128 = deposit_amount_lp * pool.reserve1 / total;
        let deposit_amount_2: u128 = deposit_amount_lp * pool.reserve2 / total;

        // automatic underflow check ensures a user didn't request more than they have on this deposit
        let change1: u128 = deposit_amount_1 - token1_amount;
        let change2: u128 = deposit_amount_2 - token2_amount;

        assert (!Mapping::contains(amm_extras, extra_voucher1)); // check if voucher1 is already in use
        Mapping::set(amm_extras, extra_voucher1, ExtraAmount {
            token_id: token1_id,
            token_amount: change1
        });

        assert (!Mapping::contains(amm_extras, extra_voucher2)); // check if voucher2 is already in use
        Mapping::set(amm_extras, extra_voucher2, ExtraAmount {
            token_id: token2_id,
            token_amount: change2
        });

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.reserve1 - deposit_amount_1,
            reserve2: pool.reserve2 - deposit_amount_2,
            lp_total_supply: pool.lp_total_supply - deposit_amount_lp,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool_key, updated_pool);
        Mapping::remove(amm_deposits, deposit_id);
    }

    transition swap_amm_puc_in(receiver: address, amount_in: u128, token_out_id: u64, amount_out: u128, extra_voucher: field) -> (arcanetoken.leo/ArcaneToken, ExtraAmountVoucher) {
        assert(amount_out > 0u128);

        let token_out: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(token_out_id, receiver, amount_out);

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token_out_id,
            voucher: extra_voucher
        };

        return (token_out, extra_amount_voucher) then finalize(amount_in, token_out_id, amount_out, extra_voucher);
    }

    finalize swap_amm_puc_in(amount_in: u128, token_out_id: u64, amount_out: u128, extra_change_voucher: field) {
        let token_in_id: u64 = 0u64;

        let pool_key: field = get_pool_key(token_in_id, token_out_id);
        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let total: u128 = pool.lp_total_supply;

        // credits.leo/credits
        let reserve_in: u128 = pool.token1_id == token_in_id ? pool.reserve1 : pool.reserve2;
        let reserve_out: u128 = pool.token2_id == token_in_id ? pool.reserve1 : pool.reserve2;

        let fee: u128 = pool.swap_fee;

        let amount_in_with_fee: u128 = amount_in * (10000u128 - fee);
        let actual_amount_out: u128 = amount_in_with_fee * reserve_out / (reserve_in * 10000u128 + amount_in_with_fee);
        assert(actual_amount_out >= amount_out);

        // Return change
        let extra_change: u128 = actual_amount_out - amount_out;

        let extra_amount: ExtraAmount = ExtraAmount {
            token_id: token_out_id,
            token_amount: extra_change,
        };
        Mapping::set(amm_extras, extra_change_voucher, extra_amount);

        // Update pool
        let reserve_in_new: u128 = reserve_in + amount_in;
        let reserve_out_new: u128 = reserve_out - actual_amount_out;

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.token1_id == token_in_id ? reserve_in_new : reserve_out_new,
            reserve2: pool.token2_id == token_in_id ? reserve_in_new : reserve_out_new,
            lp_total_supply: pool.lp_total_supply,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };

        Mapping::set(amm_pools, pool_key, updated_pool);
    }

    transition swap_amm_pric_in(receiver: address, token_in: credits.leo/credits, amount_in: u64, token_out_id: u64, amount_out: u128, extra_voucher: field) -> (credits.leo/credits, arcanetoken.leo/ArcaneToken, ExtraAmountVoucher) {
        assert(amount_out > 0u128);
        assert(amount_in > 0u64);

        let change: credits = credits.leo/transfer_private_to_public(token_in, SELF_ADDRESS, amount_in);
        let token_out: ArcaneToken = arcanetoken.leo/transfer_public_to_private_arc(token_out_id, receiver, amount_out);

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: token_out_id,
            voucher: extra_voucher
        };

        return (change, token_out, extra_amount_voucher) then finalize(amount_in as u128, token_out_id, amount_out, extra_voucher);
    }

    finalize swap_amm_pric_in(amount_in: u128, token_out_id: u64, amount_out: u128, extra_change_voucher: field) {
        let token_in_id: u64 = 0u64;

        let pool_key: field = get_pool_key(token_in_id, token_out_id);
        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let total: u128 = pool.lp_total_supply;

        let reserve_in: u128 = pool.token1_id == token_in_id ? pool.reserve1 : pool.reserve2;
        let reserve_out: u128 = pool.token2_id == token_in_id ? pool.reserve1 : pool.reserve2;

        let fee: u128 = pool.swap_fee;

        let amount_in_with_fee: u128 = amount_in * (10000u128 - fee);
        let actual_amount_out: u128 = amount_in_with_fee * reserve_out / (reserve_in * 10000u128 + amount_in_with_fee);
        assert(actual_amount_out >= amount_out);

        // Return change
        let extra_change: u128 = actual_amount_out - amount_out;

        let extra_amount: ExtraAmount = ExtraAmount {
            token_id: token_out_id,
            token_amount: extra_change,
        };
        Mapping::set(amm_extras, extra_change_voucher, extra_amount);

        // Update pool
        let reserve_in_new: u128 = reserve_in + amount_in;
        let reserve_out_new: u128 = reserve_out - actual_amount_out;

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.token1_id == token_in_id ? reserve_in_new : reserve_out_new,
            reserve2: pool.token2_id == token_in_id ? reserve_in_new : reserve_out_new,
            lp_total_supply: pool.lp_total_supply,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };

        Mapping::set(amm_pools, pool_key, updated_pool);
    }

    transition swap_amm_pric_out(receiver: address, token_in: arcanetoken.leo/ArcaneToken, amount_in: u128, amount_out: u64, extra_voucher: field) -> (arcanetoken.leo/ArcaneToken, credits.leo/credits, ExtraAmountVoucher) {
        assert(amount_out > 0u64);

        let change: ArcaneToken = arcanetoken.leo/transfer_private_to_public_arc(token_in, SELF_ADDRESS, amount_in);
        let token_out: credits = credits.leo/transfer_public_to_private(receiver, amount_out);

        // user can get change using this voucher if amount_out is less than actual amount they could receive according to AMM math
        let extra_amount_voucher: ExtraAmountVoucher = ExtraAmountVoucher {
            owner: receiver,
            token_id: 0u64,
            voucher: extra_voucher
        };

        return (change, token_out, extra_amount_voucher) then finalize(token_in.token_id, amount_in, amount_out as u128, extra_voucher);
    }

    finalize swap_amm_pric_out(token_in_id: u64, amount_in: u128, amount_out: u128, extra_change_voucher: field) {
        let token_out_id: u64 = 0u64;

        let pool_key: field = get_pool_key(token_in_id, token_out_id);
        let pool: PoolInfo = Mapping::get(amm_pools, pool_key);

        let total: u128 = pool.lp_total_supply;

        let reserve_in: u128 = pool.token1_id == token_in_id ? pool.reserve1 : pool.reserve2;
        let reserve_out: u128 = pool.token2_id == token_in_id ? pool.reserve1 : pool.reserve2;

        let fee: u128 = pool.swap_fee;

        let amount_in_with_fee: u128 = amount_in * (10000u128 - fee);
        let actual_amount_out: u128 = amount_in_with_fee * reserve_out / (reserve_in * 10000u128 + amount_in_with_fee);
        assert(actual_amount_out >= amount_out);

        // Return change
        let extra_change: u128 = actual_amount_out - amount_out;

        let extra_amount: ExtraAmount = ExtraAmount {
            token_id: token_out_id,
            token_amount: extra_change,
        };
        Mapping::set(amm_extras, extra_change_voucher, extra_amount);

        // Update pool
        let reserve_in_new: u128 = reserve_in + amount_in;
        let reserve_out_new: u128 = reserve_out - actual_amount_out;

        let updated_pool: PoolInfo = PoolInfo {
            id: pool.id,
            token1_id: pool.token1_id,
            token2_id: pool.token2_id,
            swap_fee: pool.swap_fee,
            reserve1: pool.token1_id == token_in_id ? reserve_in_new : reserve_out_new,
            reserve2: pool.token2_id == token_in_id ? reserve_in_new : reserve_out_new,
            lp_total_supply: pool.lp_total_supply,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };

        Mapping::set(amm_pools, pool_key, updated_pool);
    }

    transition redeem_voucher_pric(voucher: ExtraAmountVoucher, amount: u64) -> (credits.leo/credits) {
        assert (voucher.token_id == 0u64);
        let token: credits = credits.leo/transfer_public_to_private(voucher.owner, amount);
        return token then finalize(voucher.voucher, amount as u128);
    }

    finalize redeem_voucher_pric(voucher_code: field, amount: u128) {
        let extra: ExtraAmount = Mapping::get(amm_extras, voucher_code);
        assert (extra.token_id == 0u64 && extra.token_amount == amount);
        Mapping::remove(amm_extras, voucher_code);
    }

    /// ██████████████████████████████████████████████████████████████████████
    ///                             DEMO
    /// ██████████████████████████████████████████████████████████████████████

    transition init_demo_pools(dummy: field) {
        return then finalize();
    }

    finalize init_demo_pools() {
        let reserve1: u128 = 100000000000000u128;
        let reserve2: u128 = 100000000000000u128;
        let reserve3: u128 = 50000000000u128;
        let reserve4: u128 = 500000000000u128;

        let pool12_key: field = get_pool_key(1u64, 2u64);
        let pool12: PoolInfo = PoolInfo {
            id: pool12_key, // hash(token1.id, token2.id)
            token1_id: 1u64,
            token2_id: 2u64,
            reserve1: reserve1,
            reserve2: reserve2,
            lp_total_supply: reserve1 * reserve2,
            swap_fee: 10u128, // 10000 based, 1 = 0.01% = 0.0001
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        assert(!Mapping::contains(amm_pools, pool12_key));
        Mapping::set(amm_pools, pool12_key, pool12);

        let pool13_key: field = get_pool_key(1u64, 3u64);
        let pool13: PoolInfo = PoolInfo {
            id: pool13_key,
            token1_id: 1u64,
            token2_id: 3u64,
            reserve1: reserve1,
            reserve2: reserve3,
            lp_total_supply: reserve1 * reserve3,
            swap_fee: 10u128, // 10000 based, 1 = 0.01% = 0.0001
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool13_key, pool13);

        let pool14_key: field = get_pool_key(1u64, 4u64);
        let pool14: PoolInfo = PoolInfo {
            id: pool14_key,
            token1_id: 1u64,
            token2_id: 4u64,
            reserve1: reserve1,
            reserve2: reserve4,
            lp_total_supply: reserve1 * reserve4,
            swap_fee: 10u128,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool14_key, pool14);

        let pool23_key: field = get_pool_key(2u64, 3u64);
        let pool23: PoolInfo = PoolInfo {
            id: pool23_key, // hash(token1.id, token2.id)
            token1_id: 2u64,
            token2_id: 3u64,
            reserve1: reserve2,
            reserve2: reserve3,
            lp_total_supply: reserve2 * reserve3,
            swap_fee: 10u128,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
            };
        Mapping::set(amm_pools, pool23_key, pool23);

        let pool24_key: field = get_pool_key(2u64, 4u64);
        let pool24: PoolInfo = PoolInfo {
            id: pool24_key,
            token1_id: 2u64,
            token2_id: 4u64,
            reserve1: reserve2,
            reserve2: reserve4,
            lp_total_supply: reserve2 * reserve4,
            swap_fee: 10u128,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool24_key, pool24);

        let pool34_key: field = get_pool_key(3u64, 4u64);
        let pool34: PoolInfo = PoolInfo {
            id: pool34_key,
            token1_id: 3u64,
            token2_id: 4u64,
            reserve1: reserve3,
            reserve2: reserve4,
            lp_total_supply: reserve3 * reserve4,
            swap_fee: 10u128,
            tick: 0i32,
            t0_protocol_fees: 0u128,
            t1_protocol_fees: 0u128,
            tick_spacing: 0u8,
            max_liq_per_tick: 0u64,
            feeGrowthGlobal0X32: 0u64,
            feeGrowthGlobal1X32: 0u64
        };
        Mapping::set(amm_pools, pool34_key, pool34);
    }

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

    transition main(a: u64, b: u64) -> u64 {
        let c: u64 = lm_add_delta(1u64, 1i64);
        return mul_mod(a, b + c, 123u64);
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
        let z: u64 = 0u64;
        if y < 0i64 {
            z = x - (y.abs() as u64);
            assert(z < x);
        } else {
            z = x + (y.abs() as u64);
            assert(z >= x);
        }
        return z;
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

    function get_position_info_key(owned_by: address, tick_lower: i32, tick_upper: i32) -> field {
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
        tick: i32,
        lower_tick_info: TickInfo,
        upper_tick_info: TickInfo,
        pool_info: PoolInfo,
    ) -> UpdatePositionResult {
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

        let fee_growth_global0_X32: u64 = pool_info.feeGrowthGlobal0X32;
        let fee_growth_global1_X32: u64 = pool_info.feeGrowthGlobal1X32;

        if (liquidity_delta != 0i64) {
            let lower_res: (TickInfo, bool) = ticks_update(
                lower_tick_info,
                tick_lower,
                tick,
                liquidity_delta,
                fee_growth_global0_X32,
                fee_growth_global1_X32,
                false, // is upper
                pool_info.max_liq_per_tick // maxLiquidity
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
                pool_info.max_liq_per_tick // maxLiquidity
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
    /// @param secondsPerLiquidityCumulativeX128 The all-time seconds per max(1, liquidity) of the pool
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
        /// @param secondsPerLiquidityCumulativeX128 The current seconds per liquidity
        /// @param time The current block.timestamp
        /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
        inline cross(
            info: TickInfo,
            tick: i32,
            feeGrowthGlobal0X32: u64,
            feeGrowthGlobal1X32: u64
        ) -> (TickInfo, i64) {
            let updated_info: TickInfo = TickInfo {
                                liquidityGross: info.liquidityGross,
                                liquidityNet: info.liquidityNet,
                                feeGrowthOutside0X32: feeGrowthGlobal0X32 - info.feeGrowthOutside0X32,
                                feeGrowthOutside1X32: feeGrowthGlobal1X32 - info.feeGrowthOutside1X32,
                                initialized: info.initialized
            };
            let liquidityNet: i64 = info.liquidityNet;

            return (updated_info, liquidityNet);
        }

}