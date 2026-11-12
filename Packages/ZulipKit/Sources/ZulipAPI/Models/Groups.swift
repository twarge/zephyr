import Foundation

/// A user group (register `realm_user_groups`), system role groups included.
/// Only what permission checks need is modeled.
public struct UserGroup: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var members: [Int]?
    public var directSubgroupIds: [Int]?
}

/// The value of a group-based permission setting: a group id, or an
/// anonymous group of direct members and subgroups.
public enum GroupSettingValue: Decodable, Sendable, Hashable {
    case group(Int)
    case anonymous(members: [Int], subgroups: [Int])

    private enum CodingKeys: String, CodingKey {
        case directMembers, directSubgroups
    }

    public init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(Int.self) {
            self = .group(id)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .anonymous(
            members: try container.decodeIfPresent([Int].self, forKey: .directMembers) ?? [],
            subgroups: try container.decodeIfPresent([Int].self, forKey: .directSubgroups) ?? [])
    }

    /// Whether the user holds the permission; `groupIds` is every group
    /// the user belongs to, subgroup membership included.
    public func contains(userId: Int, groupIds: Set<Int>) -> Bool {
        switch self {
        case .group(let id):
            return groupIds.contains(id)
        case .anonymous(let members, let subgroups):
            return members.contains(userId) || !groupIds.isDisjoint(with: subgroups)
        }
    }
}
