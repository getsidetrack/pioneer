//
//  Closure.swift
//  Pioneer
//
//  Created by d-exclaimation.
//

/// Define an expression from a closure
/// - Returns: The returned value of this closure
func def<ReturnType>(_ fn: () -> ReturnType) -> ReturnType {
    fn()
}
