import Foundation

@main
enum NewMessageTests {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: \(what)"); exit(1) }
        print("PASS: \(what)")
    }

    static func main() {
        check(ContactResolver.sendableHandle("(770) 696-7530") == "+17706967530", "a ten digit number is taken as US")
        check(ContactResolver.sendableHandle("1 770 696 7530") == "+17706967530", "eleven digits with a leading 1")
        check(ContactResolver.sendableHandle("+44 20 7946 0958") == "+442079460958", "an international number keeps its country code")
        check(ContactResolver.sendableHandle("12345") == nil, "too short is not a number")
        check(ContactResolver.sendableHandle("Jack Fenley") == nil, "a name is not a number")
        check(ContactResolver.sendableHandle("Ana@Example.com") == "ana@example.com", "an email is lowercased")
        check(ContactResolver.sendableHandle("ana@nowhere") == nil && ContactResolver.sendableHandle("a b@x.co") == nil, "a malformed email is refused")
        let script = MessagesSender.newScript(handle: "+17706967530", text: "He said \"hi\"\nsee you")
        check(script.contains("buddy \"+17706967530\" of theService"), "the script addresses the buddy")
        check(script.contains("\"He said \\\"hi\\\"\" & linefeed & \"see you\""), "quotes and line breaks are escaped")
        check(MessagesSender.compiles(script), "the script compiles")
        print("ALL PASS")
    }
}
