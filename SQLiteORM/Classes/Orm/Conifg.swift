//
//  Conifg.swift
//  SQLiteORM
//
//  Created by Valo on 2019/5/6.
//

import Foundation

public class Config {
    public static let createAt: String = "createAt"
    public static let updateAt: String = "updateAt"

    /// 生成config的Struct/Class. 从数据表创建则为nil
    public var type: Codable.Type?

    /// 是否从数据表创建
    public var fromTable: Bool = false

    /// 所有字段
    public var columns: [String] = []

    /// 主键,可多个. FTS仅供外部增删使用
    public var primaries: [String] = []

    /// 白名单
    public var whites: [String] = []

    /// 黑名单
    public var blacks: [String] = []

    /// 索引字段
    public var indexes: [String] = []

    /// 字段:存储类型
    public var types: [String: String] = [:]

    /// 从数据类型创建配置
    ///
    /// - Parameter type: 数据类型
    public init(_ type: Codable.Type) {
        self.type = type
        let info: TypeInfo = try! typeInfo(of: type)

        var columns = [String]()
        var types = [String: String]()
        switch info.kind {
        case .class, .struct:
            for prop in info.properties {
                columns.append(prop.name)
                types[prop.name] = sqlType(of: prop.type)
            }

        default:
            assert(false, "unsupported type")
        }
        self.columns = columns
        self.types = types
    }

    /// 从数据表创建配置
    ///
    /// - Parameters:
    ///   - table: 表名
    ///   - db: 数据库
    init(table: String, db: Database) {
        fromTable = true
    }

    /// 从数据表创建配置,工厂方法
    ///
    /// - Parameters:
    ///   - table: 表名
    ///   - db: 数据库
    /// - Returns: 普通配置/FTS配置
    public class func factory(_ table: String, db: Database) -> Config {
        let fts = db.isFts(table)
        if fts {
            return FtsConfig(table: table, db: db)
        }
        return PlainConfig(table: table, db: db)
    }

    /// 预处理
    fileprivate func treate() {
        whites = Array(Set(whites))
        blacks = Array(Set(blacks))
        if whites.count > 0 {
            columns = Set(columns).intersection(whites).sorted(by: { $0 < $1 })
        } else if blacks.count > 0 {
            columns = Set(columns).subtracting(blacks).sorted(by: { $0 < $1 })
        } else {
            columns = Set(columns).sorted(by: { $0 < $1 })
        }
        indexes = Array(Set(indexes).intersection(columns))
    }

    public func createSQL(with table: String) -> String {
        return ""
    }
}

/// 普通表配置
public final class PlainConfig: Config {
    /// 是否记录数据创建/修改时间
    public var logAt: Bool = false

    /// 是否自增主键,仅当主键数量为1时有效
    public var pkAutoInc: Bool = false

    /// 非空字段
    public var notnulls: [String] = []

    /// 唯一性约束字段
    public var uniques: [String] = []

    /// 默认值配置
    public var defaultValues: [String: Binding] = [:]

    /// 从数据类型创建
    ///
    /// - Parameter type: 数据类型,Struct/Class
    public override init(_ type: Codable.Type) {
        super.init(type)
    }

    /// 从数据表创建
    ///
    /// - Parameters:
    ///   - table: 表名
    ///   - db: 数据库
    override init(table: String, db: Database) {
        super.init(table: table, db: db)
        var columns = [String]()
        var primaries = [String]()
        var notnulls = [String]()
        var uniques = [String]()
        var indexes = [String]()

        var types = [String: String]()
        var defaultValues = [String: Binding]()

        // 获取表配置
        let tableInfoSql = "PRAGMA table_info(\(table.quoted));"
        let infos = db.query(tableInfoSql)
        for dic in infos {
            let name = dic["name"] as? String ?? ""
            let type = dic["type"] as? String ?? ""
            let notnull = (dic["notnull"] as? Int64 ?? 0) > 0
            let dflt_value = dic["dflt_value"]
            let pk = (dic["pk"] as? Int64 ?? 0) > 0

            columns.append(name)
            types[name] = type
            defaultValues[name] = dflt_value
            if pk { primaries.append(name) }
            if notnull { notnulls.append(name) }
        }

        // 获取索引配置
        let indexListSql = "PRAGMA index_list(\(table.quoted));"
        let indexList = db.query(indexListSql)
        for dic in indexList {
            let idxname = dic["name"] as? String ?? ""
            let unique = (dic["unique"] as? Int64 ?? 0) > 0

            let indexInfoSql = "PRAGMA index_info(\(idxname.quoted));"
            let indexInfos = db.query(indexInfoSql)
            for idxinfo in indexInfos {
                let name = idxinfo["name"] as? String ?? ""
                if unique {
                    uniques.append(name)
                } else {
                    indexes.append(name)
                }
            }
        }

        // 获取主键配置
        var pkAutoInc = false
        if primaries.count > 0 {
            let sql = "SELECT * FROM sqlite_master WHERE tbl_name = \(table.quoted) AND type = 'table'"
            let cols = db.query(sql)
            let tableSql = cols.first?["sql"] as? String ?? ""
            if tableSql.match("AUTOINCREMENT") { pkAutoInc = true }
        }

        let logAt = columns.contains(Config.createAt) && columns.contains(Config.updateAt)

        self.logAt = logAt
        self.pkAutoInc = pkAutoInc
        self.columns = columns
        self.primaries = primaries
        self.notnulls = notnulls
        self.indexes = indexes
        self.uniques = uniques

        self.types = types
        self.defaultValues = defaultValues
    }

    /// 预处理
    public override func treate() {
        super.treate()
        primaries = Array(Set(primaries).intersection(columns))
        notnulls = Array(Set(notnulls).intersection(columns).subtracting(primaries))
        uniques = Array(Set(uniques).intersection(columns).subtracting(primaries))
        indexes = Array(Set(indexes).subtracting(uniques).subtracting(primaries))
    }

    /// 比较两个配置的索引
    ///
    /// - Parameter other: 比较的配置
    /// - Returns: true-索引相同,false-索引不同
    func isIndexesEqual(_ other: PlainConfig) -> Bool {
        treate()
        return uniques == other.uniques && indexes == other.indexes
    }

    /// 生成单个字段的创建SQL
    ///
    /// - Parameter column: 字段
    /// - Returns: SQL子句
    func createSQL(of column: String) -> String {
        let typeString = types[column] ?? ""
        var pkString = ""
        if primaries.count == 1 && primaries.contains(column) {
            pkString = pkAutoInc ? " NOT NULL PRIMARY KEY AUTOINCREMENT" : " NOT NULL PRIMARY KEY"
        }
        let nullString = notnulls.contains(column) ? " NOT NULL" : ""
        let uniqueString = uniques.contains(column) ? " UNIQUE" : ""
        let defaultValue = defaultValues[column]
        let dfltString = defaultValue != nil ? " DEFAULT(\(String(describing: defaultValue)))" : ""
        return "\(column.quoted) " + typeString + pkString + nullString + uniqueString + dfltString
    }

    /// 生成完整的普通表创建语句
    ///
    /// - Parameter table: 表名
    /// - Returns: SQL语句
    public override func createSQL(with table: String) -> String {
        treate()
        var array = columns.map { createSQL(of: $0) }
        if primaries.count > 1 {
            array.append("PRIMARY KEY (" + primaries.joined(separator: ",") + ")")
        }

        let sql = array.joined(separator: ",")
        guard sql.count > 0 else {
            return sql
        }

        return "CREATE TABLE IF NOT EXISTS \(table.quoted) (\(sql))".strip
    }
}

/// FTS表配置
public final class FtsConfig: Config {
    /// fts 模块: fts3/fts4/fts5
    public var module: String = "fts5"

    /// 分词器,比如:ascii,porter,nl,apple,sqliteorm
    public var tokenizer: String = ""

    /// fts版本号
    public var version: UInt {
        switch module {
        case let module where module.match("fts5"):
            return 5
        case let module where module.match("fts4"):
            return 4
        default:
            return 3
        }
    }

    /// 从数据类型创建
    ///
    /// - Parameter type: 数据类型,Struct/Class
    public override init(_ type: Codable.Type) {
        super.init(type)
    }

    /// 从数据表创建
    ///
    /// - Parameters:
    ///   - table: 表名
    ///   - db: 数据库
    override init(table: String, db: Database) {
        super.init(table: table, db: db)

        let sql = "SELECT * FROM sqlite_master WHERE tbl_name = \(table.quoted) AND type = 'table'"
        let cols = db.query(sql)
        let tableSql = cols.first?["sql"] as? String ?? ""
        let options: NSString.CompareOptions = [.regularExpression, .caseInsensitive]

        var module = "fts3"
        var tokenizer = ""
        var columns = [String]()
        var indexes = [String]()

        // 获取模块名,版本号
        var r = tableSql.range(of: " +fts.*\\(", options: options)
        if r != nil {
            let start = r!.lowerBound
            let end = tableSql.index(r!.upperBound, offsetBy: -1)
            module = String(tableSql[start ..< end]).trim
        }
        self.module = module
        let version = self.version

        // 获取FTS分词器
        r = tableSql.range(of: "\\(.*\\)", options: options)
        assert(r != nil, "invalid fts table")
        let ftsOptionsString = String(tableSql[r!.lowerBound ..< r!.upperBound])
        let ftsOptions = ftsOptionsString.components(separatedBy: .init(charactersIn: ",)"))
        for optionStr in ftsOptions {
            if optionStr.match("tokenize *=.*") {
                let sr = optionStr.range(of: "=.*", options: options)
                let start = optionStr.index(sr!.lowerBound, offsetBy: 1)
                tokenizer = String(optionStr[start ..< optionStr.endIndex]).trim.replacingOccurrences(of: "'|\"", with: "", options: .regularExpression)
            }
        }
        // 获取表配置
        let tableInfoSql = "PRAGMA table_info(\(table.quoted));"
        let infos = db.query(tableInfoSql)
        for dic in infos {
            let name = dic["name"] as? String ?? ""
            let regex = version == 5 ? "\(name.quoted) +UNINDEXED" : "notindexed *= *\(name.quoted)"
            if !tableSql.match(regex) {
                indexes.append(name)
            }
            columns.append(name)
        }

        self.tokenizer = tokenizer
        self.columns = columns
        self.indexes = indexes
    }

    /// 生成完整的FTS表创建语句
    ///
    /// - Parameter table: 表名
    /// - Returns: SQL语句
    public override func createSQL(with table: String) -> String {
        treate()
        let notindexeds = Set(columns).subtracting(indexes)
        var sql = ""
        for column in columns {
            sql += ", \(column.quoted)"
            if notindexeds.contains(column) && version >= 5 {
                sql += " UNINDEXED"
            }
        }
        if version == 4 && notindexeds.count > 0 {
            for column in notindexeds {
                sql += ", notindexed=\(column.quoted)"
            }
        }
        guard sql.count > 2 else {
            return ""
        }
        sql.removeFirst(2)

        let tokenize = tokenizer.count == 0 ? "" : (version < 5 ? ", tokenize=\(tokenizer)" : ", tokenize = '\(tokenizer)'")
        return "CREATE VIRTUAL TABLE IF NOT EXISTS \(table.quoted) USING \(module)(\(sql) \(tokenize))".strip
    }
}

extension Config: Equatable {
    /// `==`运算符重载,比较两个配置是否一致
    ///
    /// - Parameters:
    ///   - lhs: 左值
    ///   - rhs: 右值
    /// - Returns: 是否一致
    public static func == (lhs: Config, rhs: Config) -> Bool {
        lhs.treate()
        rhs.treate()
        switch (lhs, rhs) {
        case let (lhs as PlainConfig, rhs as PlainConfig):
            return lhs.pkAutoInc == rhs.pkAutoInc &&
                lhs.columns === rhs.columns &&
                lhs.types == rhs.types &&
                lhs.primaries === rhs.primaries &&
                lhs.notnulls === rhs.notnulls &&
                lhs.defaultValues === rhs.defaultValues

        case let (lhs as FtsConfig, rhs as FtsConfig):
            return lhs.module == rhs.module &&
                lhs.tokenizer == rhs.tokenizer &&
                lhs.columns === rhs.columns &&
                lhs.indexes === rhs.indexes

        default: return false
        }
    }
}
