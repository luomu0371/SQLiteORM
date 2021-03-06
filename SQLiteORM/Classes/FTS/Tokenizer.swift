//
//  Tokenizer.swift
//  SQLiteORM
//
//  Created by Valo on 2019/5/21.
//

import Foundation
import NaturalLanguage

public typealias Token = SQLiteORMToken

public enum TokenMethod: Int {
    case apple, natural, sqliteorm
    case unknown = 0xFFFF
}

public struct TokenMask: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let pinyin = TokenMask(rawValue: 1 << 0)
    public static let initial = TokenMask(rawValue: 1 << 1)
    public static let number = TokenMask(rawValue: 1 << 2)
    public static let transform = TokenMask(rawValue: 1 << 3)

    public static let `default` = TokenMask([.number, .transform])
    public static let all = TokenMask(rawValue: 0xFFFFFFFF)
}

private enum TokenType: Int {
    case none = 0, letter, digit, symbol, other
    case auxiliary
}

private struct TokenCursor {
    var type: TokenType = .none
    var offset: Int = 0
    var len: Int = 0
}

@_silgen_name("swift_tokenize")
public func swift_tokenize(_ source: NSString, _ method: Int, _ mask: UInt32) -> NSArray {
    guard source.length > 0 else { return [] as NSArray }
    let bytes = source.lowercased.bytes
    return tokenize(bytes, TokenMethod(rawValue: method) ?? .unknown, .init(rawValue: mask)) as NSArray
}

public func tokenize(_ bytes: [UInt8], _ method: TokenMethod = .unknown, _ mask: TokenMask) -> [Token] {
    var tokens: [Token] = []
    switch method {
    case .apple: tokens = appleTokenize(bytes, mask: mask)
    case .natural: tokens = naturalTokenize(bytes, mask: mask)
    case .sqliteorm: tokens = ormTokenize(bytes, mask: mask)
    default: break
    }
    tokens = Array(Set(tokens))
    tokens.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    return tokens
}

/// 自然语言处理分词
private func naturalTokenize(_ bytes: [UInt8], mask: TokenMask, locale: String = "") -> [Token] {
    guard bytes.count > 0 else { return [] }
    let source = String(bytes: bytes)

    var results: [Token] = []
    if #available(OSX 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *) {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = source
        if locale.count > 0 {
            tokenizer.setLanguage(NLLanguage(rawValue: locale))
        }
        let range = source.startIndex ..< source.endIndex
        tokenizer.enumerateTokens(in: range) { (tokenRange, _) -> Bool in
            let tk = source[tokenRange]
            let pre = source[source.startIndex ..< tokenRange.lowerBound]
            let start = pre.utf8.count
            let len = tk.utf8.count
            let token = Token(String(tk), len: Int32(len), start: Int32(start), end: Int32(start + len))
            results.append(token)
            return true
        }
    }
    guard mask.contains(.number) else { return results }
    let numberTks = numberTokens(of: bytes, mask: mask)
    return results + numberTks
}

/// CoreFundation分词
private func appleTokenize(_ bytes: [UInt8], mask: TokenMask, locale: String = "") -> [Token] {
    guard bytes.count > 0 else { return [] }
    let source = String(bytes: bytes)

    var results: [Token] = []
    let cfText = source as CFString
    let cfRange = CFRangeMake(0, source.count)
    let cfLocale = locale.count > 0 ? Locale(identifier: locale) as CFLocale : CFLocaleCopyCurrent()

    let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, cfText, cfRange, kCFStringTokenizerUnitWordBoundary, cfLocale)
    guard tokenizer != nil else { return results }

    var tokenType = CFStringTokenizerGoToTokenAtIndex(tokenizer!, 0)
    var range: CFRange

    while tokenType != .init(rawValue: 0) {
        range = CFStringTokenizerGetCurrentTokenRange(tokenizer!)
        let startBound = source.startIndex
        let lowerBound = source.index(startBound, offsetBy: range.location)
        let upperBound = source.index(startBound, offsetBy: range.location + range.length)
        let tk = source[lowerBound ..< upperBound]
        let pre = source[startBound ..< lowerBound]
        let len = tk.utf8.count
        let start = pre.utf8.count
        let token = Token(String(tk), len: Int32(len), start: Int32(start), end: Int32(start + len))
        results.append(token)
        tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer!)
    }
    guard mask.contains(.number) else { return results }
    let numberTks = numberTokens(of: bytes, mask: mask)
    return results + numberTks
}

/// SQLiteORM分词
private func ormTokenize(_ bytes: [UInt8], mask: TokenMask) -> [Token] {
    guard bytes.count > 0 else { return [] }

    let cs = cursors(of: bytes)
    let results = ormTokens(of: bytes, cursors: cs, mask: mask)
    guard mask.contains(.number) else { return results }
    let numberTks = numberTokens(of: bytes, mask: mask)
    return results + numberTks
}

private var symbolsSet: NSCharacterSet = {
    var set = CharacterSet()
    set.formUnion(.controlCharacters)
    set.formUnion(.whitespacesAndNewlines)
    set.formUnion(.nonBaseCharacters)
    set.formUnion(.punctuationCharacters)
    set.formUnion(.symbols)
    set.formUnion(.illegalCharacters)
    return set as NSCharacterSet
}()

private func isSymbol(_ ch: unichar) -> Bool {
    return symbolsSet.characterIsMember(ch)
}

private func cursors(of bytes: [UInt8]) -> [TokenCursor] {
    guard bytes.count > 0 else { return [] }
    let sourceLen = bytes.count

    var cursors: [TokenCursor] = []
    var len = 0
    var type: TokenType = .none
    var end = false
    var offset = 0

    while offset < sourceLen {
        autoreleasepool { () -> Void in
            let ch = bytes[offset]
            if ch < 0xC0 {
                len = 1
                if ch >= 0x30 && ch <= 0x39 {
                    type = .digit
                } else if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) {
                    type = .letter
                } else {
                    type = isSymbol(unichar(ch)) ? .symbol : .other
                }
            } else if ch < 0xF0 {
                var unicode: unichar = 0
                if ch < 0xE0 {
                    len = 2
                    unicode = unichar(ch) & 0x1F
                } else {
                    len = 3
                    unicode = unichar(ch) & 0x0F
                }
                for j in (offset + 1) ..< (offset + len) {
                    if j < sourceLen {
                        unicode = (unicode << 6) | (unichar(bytes[j]) & 0x3F)
                    } else {
                        type = .none
                        len = sourceLen - j
                        end = true
                    }
                }
                if !end {
                    type = isSymbol(unichar(ch)) ? .symbol : .other
                }
            } else {
                type = .auxiliary
                if ch < 0xF8 {
                    len = 4
                } else if ch < 0xFC {
                    len = 5
                } else {
                    len = 3 // split every chinese character
                    // len = 6; // split every two chinese characters
                }
            }

            if end { return }
            cursors.append(TokenCursor(type: type, offset: offset, len: len))
            offset += len
        }
    }
    cursors.append(TokenCursor(type: .none, offset: sourceLen, len: 0))

    return cursors
}

private func wordTokens(of bytes: [UInt8], cursors: [TokenCursor], encoding: String.Encoding) -> [Token] {
    guard bytes.count > 0, cursors.count > 0 else { return [] }

    let count = cursors.count
    let last = cursors.last!

    var tokens: [Token] = []

    let extIsChar = last.type.rawValue < TokenType.symbol.rawValue
    let extCount = extIsChar ? 2 : 1

    for i in 0 ..< count {
        let c1 = cursors[i]
        let loc = c1.offset
        var len = c1.len
        for j in 1 ... extCount {
            if i + j >= count { break }
            let c2 = cursors[i + j]
            len += c2.len
        }
        let sub = [UInt8](bytes[loc ..< (loc + len)])
        if let text = String(bytes: sub, encoding: encoding), text.count > 0 {
            let token = Token(text, len: Int32(len), start: Int32(loc), end: Int32(loc + len))
            tokens.append(token)
        }
    }

    return tokens
}

private func pinyinTokens(of bytes: [UInt8], cursors: [TokenCursor], mask: TokenMask) -> [Token] {
    guard mask.contains(.pinyin), bytes.count > 0, cursors.count > 0 else { return [] }
    var results: [Token] = []
    for c in cursors {
        if c.type != .other { continue }
        let sub = bytes[c.offset ..< (c.offset + c.len)]
        if let s = String(bytes: sub, encoding: .utf8) {
            let pinyins = s.pinyins
            for pinyin in pinyins.fulls {
                let token = Token(pinyin, len: Int32(pinyin.count), start: Int32(c.offset), end: Int32(c.offset + c.len))
                results.append(token)
            }
            if mask.contains(.initial) {
                for pinyin in pinyins.abbrs {
                    let token = Token(pinyin, len: Int32(pinyin.count), start: Int32(c.offset), end: Int32(c.offset + c.len))
                    results.append(token)
                }
            }
        }
    }
    return results
}

private func pinyinTokens(bySplit fragment: String, start: Int) -> [Token] {
    let splited = fragment.splitedPinyins
    var results: [Token] = []
    for sub in splited {
        var offset = 0
        for i in 0 ..< (sub.count - 1) {
            let pinyin = sub[i]
            let token = Token(pinyin, len: Int32(pinyin.count), start: Int32(start + offset), end: Int32(start + offset + pinyin.count))
            results.append(token)
            offset += pinyin.count
        }
    }
    results = Array(Set(results))
    return results
}

private func numberTokens(of bytes: [UInt8], mask: TokenMask) -> [Token] {
    guard mask.contains(.number), bytes.count > 3 else { return [] }

    var array: [(String, Int)] = []
    var offset = 0
    let copied = bytes + [0x0]
    var container: [UInt8] = []

    for i in 0 ..< copied.count {
        let ch = copied[i]
        let flag = (ch >= 0x30 && ch <= 0x39) || ch == 0x2C
        if flag {
            container.append(ch)
            offset += 1
        } else {
            if offset > 0 {
                let numberString = String(bytes: container, encoding: .ascii) ?? ""
                array.append((numberString, i - offset))
            }
            offset = 0
            container = []
        }
    }

    var results: [Token] = []
    for (origin, offset) in array {
        let num = origin.numberWithoutSeparator
        if num.count <= 3 || num.count >= origin.count { continue }
        let numbytes = num.bytes
        let cs = cursors(of: numbytes)
        let tokens = wordTokens(of: numbytes, cursors: cs, encoding: .ascii)
        let count = tokens.count
        assert(count == num.count, "Invalid tokens.")
        var fill = 3 - count % 3
        if fill == 3 { fill = 0 }
        var sub: [Token] = []
        for i in 0 ..< (count - 2) {
            let token = tokens[i]
            let comma1 = (i + fill) / 3
            let comma2 = (i >= (count - 3) || ((i + fill) % 3 == 0)) ? 0 : 1
            let pre = offset + comma1
            token.start += Int32(pre)
            token.end += Int32(pre + comma2)
            sub.append(token)
            if (i + fill) % 3 == 2 && token.token.count == 3 {
                let tk = Token()
                tk.start = token.start
                tk.end = token.end - 1
                tk.token = (token.token as NSString).substring(to: 2) as String
                tk.len = 2
                sub.append(tk)
            }
        }
        results += sub
    }

    return results
}

private func ormTokens(of bytes: [UInt8], cursors: [TokenCursor], mask: TokenMask) -> [Token] {
    guard bytes.count > 0, cursors.count > 0 else { return [] }

    var results: [Token] = []
    var last: TokenType = .none

    var subs: [TokenCursor] = []
    for c in cursors {
        let change = c.type != last
        var encoding: String.Encoding = .init(rawValue: UInt.max)
        if change {
            switch last {
            case .letter, .digit: encoding = .ascii
            default: encoding = .utf8
            }
            if encoding.rawValue != .max {
                let tokens = wordTokens(of: bytes, cursors: subs, encoding: encoding)
                results.append(contentsOf: tokens)
            }
            last = c.type
            subs.removeAll()
        }
        subs.append(c)
    }
    return results
}
