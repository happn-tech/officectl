/*
 * LDAPUtils.swift
 * OfficeKit
 *
 * Created by François Lamboley on 11/09/2018.
 */

import Foundation

import COpenLDAP



func ldapModAlloc(method: Int32, key: String, values: [Data]) -> UnsafeMutablePointer<LDAPMod> {
	var bervalValues = (values as [Data?] + [nil]).map{ value -> UnsafeMutablePointer<berval>? in
		guard let value = value else {return nil}
		return value.withUnsafeBytes{ (valueBytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<berval> in
			let valueBytes = valueBytes.bindMemory(to: Int8.self).baseAddress!
			return ber_mem2bv(valueBytes, ber_len_t(value.count), 1 /* Duplicate the bytes */, nil /* Where to copy to. If nil, allocates a new berval. */)
		}
	}
	
	let bervalValuesPtr = UnsafeMutablePointer<UnsafeMutablePointer<berval>?>.allocate(capacity: bervalValues.count)
	bervalValuesPtr.initialize(from: &bervalValues, count: bervalValues.count)
	
	let ptr = UnsafeMutablePointer<LDAPMod>.allocate(capacity: 1)
	ptr.pointee.mod_op = method
	ptr.pointee.mod_type = ber_strdup(key)
	ptr.pointee.mod_vals = mod_vals_u(modv_bvals: bervalValuesPtr)
	return ptr
}

/* From https://github.com/PerfectlySoft/Perfect-LDAP/blob/3ec5155c2a3efa7aa64b66353024ed36ae77349b/Sources/PerfectLDAP/Utilities.swift */
func withCLDAPArrayOfString<R>(array: [String]?, _ body: (UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) throws -> R) rethrows -> R {
	guard let array = array else {
		return try body(nil)
	}
	
	/* Convert array to NULL-terminated array of pointers */
	var parr = (array as [String?] + [nil]).map{ $0.flatMap{ ber_strdup($0) } }
	defer {parr.forEach{ ber_memfree($0) }}
	
	return try parr.withUnsafeMutableBufferPointer{ try body($0.baseAddress) }
}
