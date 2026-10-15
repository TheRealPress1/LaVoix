import Foundation

// Synthetic conversations with known answers, used to measure what on-device models can do for myOS
// ("who was mentioned", "what do I know about this person", "what do I owe", "answer or admit you don't know").
// Everything here is made up. Generation is seeded, so a given seed always yields the same cases.

enum EvalTask: String, CaseIterable, Codable {
    case mentions, facts, commitments, qa
}

struct EvalPerson: Codable, Equatable {
    var id: String
    var name: String
    var org: String
}

struct EvalFact: Codable, Equatable {
    var kind: String
    var value: String
}

struct EvalCommitment: Codable, Equatable {
    var owner: String // "me" or "them"
    var what: String
    var due: String? // yyyy-MM-dd
}

/// What a model must produce (also the expected answer inside a case).
enum EvalAnswer: Equatable {
    case mentions(ids: [String])
    case facts([EvalFact])
    case commitments([EvalCommitment])
    case qa(answer: String, answerable: Bool)
}

struct EvalCase {
    let id: String
    let task: EvalTask
    let variant: String
    let system: String
    let jsonShape: String
    let input: String
    let expected: EvalAnswer
    /// Values that must NOT appear (distractors); used by facts and qa scoring.
    var forbidden: [String] = []
    /// qa only: words the answer must contain (all of them) when the question is answerable.
    var requiredWords: [String] = []
}

struct EvalRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum EvalCorpus {
    static let firstNames = ["Jimmy", "Maya", "Dana", "Priya", "Tomas", "Lena", "Omar", "Sofia", "Kenji", "Ruth", "Marcus", "Ines", "Felix", "Nadia", "Hugo", "Tess"]
    static let lastNames = ["Alvarez", "Chen", "Okafor", "Brandt", "Kowalski", "Ito", "Moreau", "Haddad", "Lindqvist", "Reyes", "Novak", "Abbott"]
    static let orgs = ["Acme", "Northwind", "Lumen Labs", "Harbor Bank", "Pinecone Studio", "Delta Freight", "Orbit Health", "Quartz Media"]
    static let cities = ["Austin", "Denver", "Lisbon", "Montreal", "Seattle", "Berlin", "Chicago", "Nairobi", "Osaka", "Dublin"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let pets = ["Biscuit", "Pepper", "Mochi", "Waffles", "Juniper", "Ziggy"]
    static let partners = ["Alex", "Sam", "Jordan", "Robin", "Casey", "Morgan"]

    static func cases(seed: UInt64, perTask: Int) -> [EvalCase] {
        var out: [EvalCase] = []
        for (t, task) in EvalTask.allCases.enumerated() {
            for i in 0 ..< perTask {
                var rng = EvalRNG(seed: seed &* 1_000_003 &+ UInt64(i) &* 7919 &+ UInt64(t) &* 104_729)
                switch task {
                case .mentions: out.append(self.mentionsCase(index: i, rng: &rng))
                case .facts: out.append(self.factsCase(index: i, rng: &rng))
                case .commitments: out.append(self.commitmentsCase(index: i, rng: &rng))
                case .qa: out.append(self.qaCase(index: i, rng: &rng))
                }
            }
        }
        return out
    }

    // MARK: - Mentions

    static let mentionsSystem = """
    You find which known people are mentioned in a meeting transcript. You get a list of known people (id, full name, \
    organisation) and the transcript. Return the ids of the people who are clearly talked about. Rules: a bare first name \
    counts only if exactly one known person has that first name; if two known people share it, count it only when the \
    surname or organisation in the transcript says which one; words used as ordinary words (will, may, mark, grace) are not \
    names; people who are not in the list are ignored. If nobody is mentioned return an empty list.
    """

    private static func mentionsCase(index: Int, rng: inout EvalRNG) -> EvalCase {
        let variants = ["unique-first-name", "full-name", "org-disambiguates", "ambiguous-bare-name", "common-word", "unknown-person", "nobody", "two-people"]
        let variant = variants[index % variants.count]
        let names = self.firstNames.shuffled(using: &rng)
        let lasts = self.lastNames.shuffled(using: &rng)
        let orgs = self.orgs.shuffled(using: &rng)
        func person(_ n: Int, first: String? = nil) -> EvalPerson {
            EvalPerson(id: "p-\(index)-\(n)", name: "\(first ?? names[n]) \(lasts[n])", org: orgs[n % orgs.count])
        }
        var people = (0 ..< 5).map { person($0) }
        var expected: [String] = []
        var lines: [String] = []
        let filler = [
            "So the Q3 numbers came in slightly under plan.",
            "Let's make sure we have the contract reviewed before the end of the month.",
            "I think the onboarding flow still has too many steps.",
            "We should loop back on pricing after the pilot.",
        ]
        lines.append(filler[Int(rng.next() % UInt64(filler.count))])
        switch variant {
        case "unique-first-name":
            lines.append("I talked to \(people[0].name.split(separator: " ")[0]) yesterday and he is fine with the schedule.")
            expected = [people[0].id]
        case "full-name":
            lines.append("\(people[1].name) sent over the draft and \(people[2].name.split(separator: " ")[0]) will review it.")
            expected = [people[1].id, people[2].id]
        case "org-disambiguates":
            let shared = "Jimmy"
            people[0] = EvalPerson(id: people[0].id, name: "\(shared) \(lasts[0])", org: orgs[0])
            people[1] = EvalPerson(id: people[1].id, name: "\(shared) \(lasts[1])", org: orgs[1])
            lines.append("\(shared) from \(orgs[1]) is going to join the call next week.")
            expected = [people[1].id]
        case "ambiguous-bare-name":
            let shared = "Jimmy"
            people[0] = EvalPerson(id: people[0].id, name: "\(shared) \(lasts[0])", org: orgs[0])
            people[1] = EvalPerson(id: people[1].id, name: "\(shared) \(lasts[1])", org: orgs[1])
            lines.append("Jimmy said he can take the follow-up, but I'm not sure he has capacity.")
            expected = []
        case "common-word":
            people[3] = EvalPerson(id: people[3].id, name: "Will \(lasts[3])", org: orgs[3])
            people[4] = EvalPerson(id: people[4].id, name: "May \(lasts[4])", org: orgs[4])
            lines.append("I will send the notes tonight and we may need another session in May.")
            expected = []
        case "unknown-person":
            lines.append("Quentin Vasquez from procurement asked about the invoice, and Whitaker wants a call too.")
            expected = []
        case "nobody":
            lines.append("Nothing else on the agenda, so let's wrap up and share the recording afterwards.")
            expected = []
        default: // two-people
            lines.append("\(people[0].name.split(separator: " ")[0]) and \(people[3].name) are both blocked on the same API change.")
            expected = [people[0].id, people[3].id]
        }
        lines.append(filler[Int(rng.next() % UInt64(filler.count))])
        let list = people.map { "- \($0.id): \($0.name) (\($0.org))" }.joined(separator: "\n")
        let input = "Known people:\n\(list)\n\nTranscript:\n\(lines.joined(separator: " "))"
        return EvalCase(id: "mentions-\(index)", task: .mentions, variant: variant, system: self.mentionsSystem, jsonShape: #"{"ids": ["p-..."]}"#, input: input, expected: .mentions(ids: expected))
    }

    // MARK: - Facts

    static let factsSystem = """
    You read a text-message thread between "Me" and one other person ("Them") and extract lasting facts about THEM only. \
    Allowed kinds: city (where they live now), employer, birthday (month and day, like "March 3"), partner (first name), \
    pet (name). Rules: facts about other people (their sister, a friend) are not facts about them; if something changed \
    (they moved, changed jobs), return only the latest value; do not guess; if there is nothing, return an empty list.
    """

    private static func factsCase(index: Int, rng: inout EvalRNG) -> EvalCase {
        let variants = ["stated-plainly", "superseded-city", "third-party-distractor", "birthday-and-pet", "nothing-to-extract", "job-change", "partner-mention"]
        let variant = variants[index % variants.count]
        let city = self.cities.randomElement(using: &rng)!
        let oldCity = self.cities.filter { $0 != city }.randomElement(using: &rng)!
        let other = self.cities.filter { $0 != city && $0 != oldCity }.randomElement(using: &rng)!
        let org = self.orgs.randomElement(using: &rng)!
        let oldOrg = self.orgs.filter { $0 != org }.randomElement(using: &rng)!
        let month = self.months.randomElement(using: &rng)!
        let day = Int(rng.next() % 27) + 1
        let pet = self.pets.randomElement(using: &rng)!
        let partner = self.partners.randomElement(using: &rng)!
        var thread: [(String, String)] = []
        var expected: [EvalFact] = []
        var forbidden: [String] = []
        switch variant {
        case "stated-plainly":
            thread = [("Me", "hey, are you around this week?"), ("Them", "yes! I'm at \(org) all week, then I fly home to \(city)"), ("Me", "nice, home is \(city) now?"), ("Them", "yes, been here three years")]
            expected = [EvalFact(kind: "employer", value: org), EvalFact(kind: "city", value: city)]
        case "superseded-city":
            thread = [("Them", "we're moving to \(oldCity) next month!"), ("Me", "congrats!!"), ("Them", "update: the \(oldCity) thing fell through, we're staying in \(city)"), ("Me", "ah ok, glad you're staying")]
            expected = [EvalFact(kind: "city", value: city)]
            forbidden = [oldCity]
        case "third-party-distractor":
            thread = [("Them", "my sister lives in \(other) and she's hosting thanksgiving"), ("Me", "fun, how's your week?"), ("Them", "busy, I live in \(city) so I can't just pop over"), ("Me", "haha true")]
            expected = [EvalFact(kind: "city", value: city)]
            forbidden = [other]
        case "birthday-and-pet":
            thread = [("Me", "happy early birthday!"), ("Them", "thanks, \(month) \(day) isn't until next week though"), ("Them", "\(pet) is getting a cake too lol"), ("Me", "is \(pet) your dog?"), ("Them", "yes my dog")]
            expected = [EvalFact(kind: "birthday", value: "\(month) \(day)"), EvalFact(kind: "pet", value: pet)]
        case "nothing-to-extract":
            thread = [("Me", "lunch tomorrow?"), ("Them", "sure, noon works"), ("Me", "great"), ("Them", "see you there")]
        case "job-change":
            thread = [("Them", "I'm still at \(oldOrg) for now"), ("Me", "any news on the other offer?"), ("Them", "yes! I start at \(org) on Monday, I resigned from \(oldOrg) today")]
            expected = [EvalFact(kind: "employer", value: org)]
            forbidden = [oldOrg]
        default: // partner-mention
            thread = [("Them", "\(partner) and I are driving up Saturday"), ("Me", "bring \(partner) to dinner"), ("Them", "will do, \(partner)'s been wanting to meet you"), ("Me", "perfect")]
            expected = [EvalFact(kind: "partner", value: partner)]
        }
        let input = self.render(thread: thread)
        return EvalCase(id: "facts-\(index)", task: .facts, variant: variant, system: self.factsSystem, jsonShape: #"{"facts": [{"kind": "city", "value": "..."}]}"#, input: input, expected: .facts(expected), forbidden: forbidden)
    }

    // MARK: - Commitments

    static let commitmentsSystem = """
    You read a text-message thread between "Me" and "Them" and list OPEN commitments: things someone promised to do and has \
    not yet done. owner is "me" if I promised it, "them" if they did. due is the deadline as yyyy-MM-dd when the thread \
    gives one (resolve words like "Friday" or "tomorrow" from the reference date: a weekday means its next occurrence after \
    the reference date), otherwise null. Do not list promises that the thread shows were completed, requests that nobody \
    agreed to, or vague pleasantries ("let's catch up soon").
    """

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func nextWeekday(_ weekday: Int, after date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var d = cal.date(byAdding: .day, value: 1, to: date)!
        while cal.component(.weekday, from: d) != weekday { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    private static func commitmentsCase(index: Int, rng: inout EvalRNG) -> EvalCase {
        let variants = ["weekday-deadline", "completed-excluded", "their-promise", "request-not-agreed", "tomorrow", "no-deadline", "mixed"]
        let variant = variants[index % variants.count]
        // Reference dates fall on varied weekdays.
        let base = isoDay.date(from: "2026-10-05")!.addingTimeInterval(Double(Int(rng.next() % 20)) * 86400)
        let ref = isoDay.string(from: base)
        let friday = isoDay.string(from: nextWeekday(6, after: base))
        let sunday = isoDay.string(from: nextWeekday(1, after: base))
        let tomorrow = isoDay.string(from: base.addingTimeInterval(86400))
        let topic = ["the deck", "the contract", "the photos", "the budget sheet"].randomElement(using: &rng)!
        let person = self.firstNames.randomElement(using: &rng)!
        var thread: [(String, String)] = []
        var expected: [EvalCommitment] = []
        switch variant {
        case "weekday-deadline":
            thread = [("Them", "can you send me \(topic)?"), ("Me", "yes, I'll send \(topic) by Friday")]
            expected = [EvalCommitment(owner: "me", what: topic, due: friday)]
        case "completed-excluded":
            thread = [("Them", "can you send me \(topic)?"), ("Me", "I'll send \(topic) tonight"), ("Me", "sent! check your inbox"), ("Them", "got it, thanks")]
        case "their-promise":
            thread = [("Me", "when can we talk about the launch?"), ("Them", "I'll call you Sunday afternoon")]
            expected = [EvalCommitment(owner: "them", what: "call", due: sunday)]
        case "request-not-agreed":
            thread = [("Them", "could you introduce me to \(person)?"), ("Me", "hmm, let me think about it"), ("Them", "no worries")]
        case "tomorrow":
            thread = [("Me", "I'll drop off the keys tomorrow"), ("Them", "perfect")]
            expected = [EvalCommitment(owner: "me", what: "keys", due: tomorrow)]
        case "no-deadline":
            thread = [("Them", "we should catch up soon"), ("Me", "definitely, I'll introduce you to \(person) at some point"), ("Them", "great")]
            expected = [EvalCommitment(owner: "me", what: "introduce", due: nil)]
        default: // mixed
            thread = [("Them", "can you send me \(topic)?"), ("Me", "I'll send \(topic) by Friday"), ("Them", "and I'll book the room for Sunday"), ("Me", "thanks"), ("Them", "also pay the invoice already!!"), ("Me", "done, paid it this morning")]
            expected = [EvalCommitment(owner: "me", what: topic, due: friday), EvalCommitment(owner: "them", what: "room", due: sunday)]
        }
        let input = "Reference date (today): \(ref)\n\n" + self.render(thread: thread)
        return EvalCase(id: "commitments-\(index)", task: .commitments, variant: variant, system: self.commitmentsSystem, jsonShape: #"{"items": [{"owner": "me", "what": "...", "due": "2026-10-09"}]}"#, input: input, expected: .commitments(expected))
    }

    // MARK: - QA

    static let qaSystem = """
    You answer a question about one person using ONLY the notes below (message excerpts and meeting notes). If the notes \
    do not contain the answer, set answerable to false and answer "unknown". Never use outside knowledge and never guess. \
    Keep the answer under 25 words.
    """

    private static func qaCase(index: Int, rng: inout EvalRNG) -> EvalCase {
        let variants = ["employer-now", "last-meeting-topic", "unanswerable-restaurant", "city-after-move", "unanswerable-salary", "summary-open-items"]
        let variant = variants[index % variants.count]
        let name = self.firstNames.randomElement(using: &rng)!
        let city = self.cities.randomElement(using: &rng)!
        let oldCity = self.cities.filter { $0 != city }.randomElement(using: &rng)!
        let org = self.orgs.randomElement(using: &rng)!
        let oldOrg = self.orgs.filter { $0 != org }.randomElement(using: &rng)!
        let topic = ["the Series A term sheet", "the Lisbon offsite", "the pricing page redesign", "the hiring plan for Q1"].randomElement(using: &rng)!
        let notes = """
        [2026-08-02 text] \(name): I just started at \(org), left \(oldOrg) last week
        [2026-08-19 meeting notes] Met \(name). Main topic: \(topic). \(name) will share a draft in two weeks.
        [2026-09-10 text] \(name): we're finally moving to \(city) from \(oldCity), boxes everywhere
        [2026-09-30 text] Me: how's the move? \(name): good, still unpacking
        """
        var question: String
        var expected: EvalAnswer
        var required: [String] = []
        var forbidden: [String] = []
        switch variant {
        case "employer-now":
            question = "Where does \(name) work now?"
            expected = .qa(answer: org, answerable: true); required = [org]; forbidden = [oldOrg]
        case "last-meeting-topic":
            question = "What did we discuss when we last met \(name)?"
            expected = .qa(answer: topic, answerable: true); required = [String(topic.split(separator: " ").last!)]
        case "unanswerable-restaurant":
            question = "What is \(name)'s favorite restaurant?"
            expected = .qa(answer: "unknown", answerable: false)
        case "city-after-move":
            question = "Which city does \(name) live in now?"
            expected = .qa(answer: city, answerable: true); required = [city]; forbidden = [oldCity]
        case "unanswerable-salary":
            question = "How much does \(name) earn at \(org)?"
            expected = .qa(answer: "unknown", answerable: false)
        default:
            question = "What's going on with \(name)? Anything I owe them or they owe me?"
            expected = .qa(answer: "draft", answerable: true); required = ["draft"]
        }
        let input = "Notes about \(name):\n\(notes)\n\nQuestion: \(question)"
        return EvalCase(id: "qa-\(index)", task: .qa, variant: variant, system: self.qaSystem, jsonShape: #"{"answer": "...", "answerable": true}"#, input: input, expected: expected, forbidden: forbidden, requiredWords: required)
    }

    // MARK: - Helpers

    private static func render(thread: [(String, String)]) -> String {
        thread.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}
