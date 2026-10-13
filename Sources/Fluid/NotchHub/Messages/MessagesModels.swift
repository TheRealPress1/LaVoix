import Foundation

struct MessageConversation: Identifiable, Equatable {
    let id: Int64
    let guid: String
    /// The group's name, or the other person's phone number / email until Contacts resolves a name.
    var title: String
    let handles: [String]
    let isGroup: Bool
    let lastText: String
    let lastDate: Date
    let lastIsFromMe: Bool
    let unreadCount: Int
    /// True when the group has been given a name; unnamed groups are shown by who is in them.
    var hasGroupName = false
}

struct ThreadMessage: Identifiable, Equatable {
    let id: Int64
    let text: String
    let date: Date
    let isFromMe: Bool
    let senderHandle: String
}

struct IncomingMessage: Equatable {
    let rowID: Int64
    let chatID: Int64
    let chatGUID: String
    let groupName: String
    let isGroup: Bool
    let senderHandle: String
    let text: String
    let date: Date
}
