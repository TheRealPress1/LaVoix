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

    /// The same conversation with a different unread count (the notch clears its own unread dot once you have looked at a chat).
    func withUnread(_ count: Int) -> MessageConversation {
        var copy = MessageConversation(id: id, guid: guid, title: title, handles: handles, isGroup: isGroup, lastText: lastText, lastDate: lastDate, lastIsFromMe: lastIsFromMe, unreadCount: count)
        copy.hasGroupName = hasGroupName
        return copy
    }
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
