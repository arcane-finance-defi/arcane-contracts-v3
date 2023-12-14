import credits.leo;
import arcanetoken.leo;

program arcane_amm_v2_0.aleo {

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

    mapping amm_pools: field => PoolInfo; // PoolInfo by hash(token1.id, token2.id)
    mapping amm_deposits: field => u128; // lp deposit amount by hash(id, pool_key)
    mapping amm_extras: field => ExtraAmount; // extra amount by voucher_id

    inline get_pool_key(token1: u64, token2: u64) -> field {
        let actual_token1: u64 = token1 > token2 ? token2 : token1;
        let actual_token2: u64 = token1 <= token2 ? token2 : token1;
        return BHP256::hash_to_field(PoolKey {token1: actual_token1, token2: actual_token2});
    }

    inline min_u128(a: u128, b: u128) -> u128 {
        return a < b ? a : b;
    }

    transition create_pool(owner: address, token1: arcanetoken.leo/ArcaneToken, initial_amount1: u128, token2: arcanetoken.leo/ArcaneToken, initial_amount2: u128, swap_fee: u128) -> (PoolAdmin, arcanetoken.leo/ArcaneToken, arcanetoken.leo/ArcaneToken) {
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

        return (pool_admin, change1, change2) then finalize(pool_key, token1.token_id, initial_amount1, token2.token_id, initial_amount2, swap_fee);
    }

    finalize create_pool(pool_key: field, token1_id: u64, token1_amount: u128, token2_id: u64, token2_amount: u128, swap_fee: u128) {
        assert (!Mapping::contains(amm_pools, pool_key)); // the pool already exists

        let pool: PoolInfo = PoolInfo {
            id: pool_key, // hash(token1.id, token2.id)
            token1_id: token1_id,
            token2_id: token2_id,
            reserve1: token1_amount,
            reserve2: token2_amount,
            lp_total_supply: token1_amount * token2_amount,
            swap_fee: swap_fee, // 10000 based, 1 = 0.01% = 0.0001
        };

        Mapping::set(amm_pools, pool_key, pool);
    }

    transition transfer_pool_ownership(poolAdmin: PoolAdmin, to: address) -> (PoolAdmin) {
        assert(poolAdmin.owner == self.caller);
        return PoolAdmin {
            owner: to,
            pool_key: poolAdmin.pool_key
        };
    }

    transition add_amm_liquidity(owner: address, 
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
            lp_total_supply: pool.lp_total_supply - deposit_amount_lp
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
            swap_fee: pool.swap_fee,
            reserve1: pool.token1_id == token_in_id ? reserve_in_new : reserve_out_new,
            reserve2: pool.token2_id == token_in_id ? reserve_in_new : reserve_out_new,
            lp_total_supply: pool.lp_total_supply
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
            lp_total_supply: pool.lp_total_supply - deposit_amount_lp
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
            lp_total_supply: pool.lp_total_supply
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
            lp_total_supply: pool.lp_total_supply
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
            lp_total_supply: pool.lp_total_supply
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
        };
        Mapping::set(amm_pools, pool34_key, pool34);
    }

    // transition tmp_get_pool_id() -> (field, field, field, field) {
    //     return (get_pool_key(1u64, 2u64), get_pool_key(1u64, 3u64), get_pool_key(2u64, 3u64), get_pool_key(2u64, 4u64));
    // }

    // transition get_my_address() -> address {
    //     return arcaneutil.leo/get_caller_address();
    // }

}