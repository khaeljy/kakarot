// SPDX-License-Identifier: MIT

%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.cairo_keccak.keccak import cairo_keccak_bigend, finalize_keccak
from starkware.cairo.common.memset import memset
from starkware.cairo.common.math import unsigned_div_rem, split_felt
from starkware.cairo.common.math_cmp import is_not_zero, is_le
from starkware.cairo.common.uint256 import Uint256, uint256_le, uint256_add

from kakarot.account import Account
from kakarot.evm import EVM
from kakarot.errors import Errors
from kakarot.gas import Gas
from kakarot.memory import Memory
from kakarot.model import model
from kakarot.stack import Stack
from kakarot.state import State
from utils.array import slice
from utils.bytes import bytes_to_bytes8_little_endian
from utils.uint256 import uint256_to_uint160
from utils.utils import Helpers

// @title Environmental information opcodes.
// @notice This file contains the functions to execute for environmental information opcodes.
namespace EnvironmentalInformation {
    func exec_address{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        let address = Helpers.to_uint256(evm.message.address.evm);
        Stack.push(address);
        return evm;
    }

    func exec_balance{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (address_uint256) = Stack.pop();
        let evm_address = uint256_to_uint160([address_uint256]);

        // Gas
        // Calling `get_account` subsequently will make the account warm for the next interaction
        let is_warm = State.is_account_warm(evm_address);
        tempvar gas = is_warm * Gas.WARM_ACCESS + (1 - is_warm) * Gas.COLD_ACCOUNT_ACCESS;
        let evm = EVM.charge_gas(evm, gas);
        if (evm.reverted != FALSE) {
            return evm;
        }

        let account = State.get_account(evm_address);
        Stack.push(account.balance);

        return evm;
    }

    func exec_origin{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        let origin_address = Helpers.to_uint256(evm.message.env.origin);

        Stack.push(origin_address);
        return evm;
    }

    func exec_caller{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        let address = Helpers.to_uint256(evm.message.caller);
        Stack.push(address);
        return evm;
    }

    func exec_callvalue{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        Stack.push(evm.message.value);

        return evm;
    }

    func exec_calldataload{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (offset) = Stack.pop();

        if (offset.high != 0) {
            Stack.push_uint128(0);
            return evm;
        }

        let (sliced_calldata: felt*) = alloc();
        slice(sliced_calldata, evm.message.calldata_len, evm.message.calldata, offset.low, 32);
        let calldata = Helpers.bytes32_to_uint256(sliced_calldata);
        Stack.push_uint256(calldata);

        return evm;
    }

    func exec_calldatasize{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        Stack.push_uint128(evm.message.calldata_len);
        return evm;
    }

    func exec_copy{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (popped) = Stack.pop_n(3);
        let dest_offset = popped[0];
        let offset = popped[1];
        let size = popped[2];

        let memory_expansion = Gas.memory_expansion_cost_saturated(
            memory.words_len, dest_offset, size
        );

        // Any size upper than 2**128 will cause an OOG error, considering the maximum gas for a transaction.
        let upper_bytes_bound = size.low + 31;
        let (words, _) = unsigned_div_rem(upper_bytes_bound, 32);
        let copy_gas_cost_low = words * Gas.COPY;
        tempvar copy_gas_cost_high = is_not_zero(size.high) * 2 ** 128;

        // static cost handled in jump table
        let evm = EVM.charge_gas(
            evm, memory_expansion.cost + copy_gas_cost_low + copy_gas_cost_high
        );
        if (evm.reverted != FALSE) {
            return evm;
        }

        let opcode_number = [evm.message.bytecode + evm.program_counter];

        // Offset.high != 0 means that the sliced data is surely 0x00...00
        // And storing 0 in Memory is just doing nothing.
        if (offset.high != 0) {
            if (opcode_number != 0x3e) {
                return evm;
            }

            // We still check for OOB returndatacopy
            let (max_index, carry) = uint256_add(offset, size);
            let (high, low) = split_felt(evm.return_data_len);
            let (is_in_bounds) = uint256_le(max_index, Uint256(low=low, high=high));
            let is_in_bounds = is_in_bounds * (1 - carry);
            if (is_in_bounds == FALSE) {
                let (revert_reason_len, revert_reason) = Errors.outOfBoundsRead();
                let evm = EVM.stop(evm, revert_reason_len, revert_reason, Errors.EXCEPTIONAL_HALT);
                return evm;
            }
            return evm;
        }

        // 0x37: calldatacopy
        // 0x39: codecopy
        // 0x3e: returndatacopy
        let (sliced_data: felt*) = alloc();
        local data_len;
        local data: felt*;
        if (opcode_number == 0x37) {
            assert data_len = evm.message.calldata_len;
            assert data = evm.message.calldata;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            if (opcode_number == 0x39) {
                assert data_len = evm.message.bytecode_len;
                assert data = evm.message.bytecode;
                tempvar range_check_ptr = range_check_ptr;
            } else {
                tempvar is_in_bounds = is_le(offset.low + size.low, evm.return_data_len);
                if (is_in_bounds == FALSE) {
                    let (revert_reason_len, revert_reason) = Errors.outOfBoundsRead();
                    let evm = EVM.stop(
                        evm, revert_reason_len, revert_reason, Errors.EXCEPTIONAL_HALT
                    );
                    return evm;
                }
                assert data_len = evm.return_data_len;
                assert data = evm.return_data;
                tempvar range_check_ptr = range_check_ptr;
            }
        }
        let range_check_ptr = [ap - 1];
        slice(sliced_data, data_len, data, offset.low, size.low);

        Memory.store_n(size.low, sliced_data, dest_offset.low);

        return evm;
    }

    func exec_codesize{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        Stack.push_uint128(evm.message.bytecode_len);
        return evm;
    }

    func exec_gasprice{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        // TODO: since gas_price is a felt, it might panic when being cast to a Uint256.low,
        // Add check gas_price < 2 ** 128
        // `split_felt` might be too expensive for this if we know gas_price < 2 ** 128
        Stack.push_uint128(evm.message.env.gas_price);

        return evm;
    }

    func exec_extcodesize{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (address_uint256) = Stack.pop();
        let evm_address = uint256_to_uint160([address_uint256]);

        // Gas
        // Calling `get_account` subsequently will make the account warm for the next interaction
        let is_warm = State.is_account_warm(evm_address);
        tempvar gas = is_warm * Gas.WARM_ACCESS + (1 - is_warm) * Gas.COLD_ACCOUNT_ACCESS;
        let evm = EVM.charge_gas(evm, gas);
        if (evm.reverted != FALSE) {
            return evm;
        }

        let account = State.get_account(evm_address);

        // bytecode_len cannot be greater than 24k in the EVM
        Stack.push_uint128(account.code_len);

        return evm;
    }

    func exec_extcodecopy{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (popped) = Stack.pop_n(4);
        let evm_address = uint256_to_uint160(popped[0]);
        let dest_offset = popped[1];
        let offset = popped[2];
        let size = popped[3];

        // Gas
        // Calling `get_account` subsequently will make the account warm for the next interaction
        let is_warm = State.is_account_warm(evm_address);
        tempvar access_gas_cost = is_warm * Gas.WARM_ACCESS + (1 - is_warm) *
            Gas.COLD_ACCOUNT_ACCESS;

        // Any size upper than 2**128 will cause an OOG error, considering the maximum gas for a transaction.
        let upper_bytes_bound = size.low + 31;
        let (words, _) = unsigned_div_rem(upper_bytes_bound, 32);
        let copy_gas_cost_low = words * Gas.COPY;
        tempvar copy_gas_cost_high = is_not_zero(size.high) * 2 ** 128;

        let memory_expansion = Gas.memory_expansion_cost_saturated(
            memory.words_len, dest_offset, size
        );

        let evm = EVM.charge_gas(
            evm, access_gas_cost + copy_gas_cost_low + copy_gas_cost_high + memory_expansion.cost
        );
        if (evm.reverted != FALSE) {
            return evm;
        }

        // Offset.high != 0 means that the sliced data is surely 0x00...00
        // And storing 0 in Memory is just doing nothing
        if (offset.high != 0) {
            return evm;
        }

        let (sliced_data: felt*) = alloc();
        let account = State.get_account(evm_address);
        slice(sliced_data, account.code_len, account.code, offset.low, size.low);

        Memory.store_n(size.low, sliced_data, dest_offset.low);

        return evm;
    }

    func exec_returndatasize{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        Stack.push_uint128(evm.return_data_len);
        return evm;
    }

    func exec_extcodehash{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
        stack: model.Stack*,
        memory: model.Memory*,
        state: model.State*,
    }(evm: model.EVM*) -> model.EVM* {
        alloc_locals;

        let (address_uint256) = Stack.pop();
        let evm_address = uint256_to_uint160([address_uint256]);

        // Gas
        // Calling `get_account` subsequently will make the account warm for the next interaction
        let is_warm = State.is_account_warm(evm_address);
        tempvar access_gas_cost = is_warm * Gas.WARM_ACCESS + (1 - is_warm) *
            Gas.COLD_ACCOUNT_ACCESS;
        let evm = EVM.charge_gas(evm, access_gas_cost);
        if (evm.reverted != FALSE) {
            return evm;
        }

        let account = State.get_account(evm_address);
        let has_code_or_nonce = Account.has_code_or_nonce(account);
        let account_exists = has_code_or_nonce + account.balance.low;
        // Relevant cases:
        // https://github.com/ethereum/go-ethereum/blob/master/core/vm/instructions.go#L392
        if (account_exists == 0) {
            Stack.push_uint128(0);
            return evm;
        }

        let (local dst: felt*) = alloc();
        bytes_to_bytes8_little_endian(dst, account.code_len, account.code);

        let (keccak_ptr: felt*) = alloc();
        local keccak_ptr_start: felt* = keccak_ptr;
        with keccak_ptr {
            let (result) = cairo_keccak_bigend(dst, account.code_len);
        }
        finalize_keccak(keccak_ptr_start=keccak_ptr_start, keccak_ptr_end=keccak_ptr);

        Stack.push_uint256(result);

        return evm;
    }
}
