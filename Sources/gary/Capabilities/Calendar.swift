import AppKit
import EventKit
import GaryCore

extension Capability {
    static let calendar = Capability(
        name: "calendar",
        summary: """
        The calendars of the user's accounts in the Calendar app, and their events in a date range. \
        The topic's count goes up whenever an event or calendar changes, so fetch the events again then.
        """,
        types: """
        declare namespace Gary {
          type CalendarChange = { available: boolean; reason?: string; count: number }
          type EventCalendar = { id: string; title: string; color: string; source: string }
          type CalendarEvent = {
            id: string;
            calendar: string;
            title: string;
            start: number;
            end: number;
            allDay: boolean;
            location: string | null;
            color: string;
          }
          interface Host { calendar: CalendarApi }
          interface CalendarApi {
            calendars(): Promise<EventCalendar[]>;
            events(start: number, end: number): Promise<CalendarEvent[]>;
          }
        }
        """,
        example: """
        let events: Gary.CalendarEvent[] = [];

        function refresh() {
          const start = new Date();
          start.setHours(0, 0, 0, 0);
          host.calendar.events(start.getTime(), start.getTime() + 86_400_000).then((today) => {
            events = today;
          });
        }

        export default {
          onTopic({ topic, value }) {
            if (topic === "calendar" && value.available) refresh();
          },
          render(state) {
            if (!state.calendar?.available) return { type: "text", text: state.calendar?.reason ?? "…", style: "dim" };
            return {
              type: "column",
              children: events.map((event) => ({
                type: "row", key: `${event.id}@${event.start}`,
                children: [
                  { type: "icon", symbol: "circle.fill", color: event.color },
                  { type: "text", text: event.allDay ? "all day" : new Date(event.start).toTimeString().slice(0, 5), style: "dim" },
                  { type: "text", text: event.title },
                ],
              })),
            };
          },
        } satisfies Gary.Panel;
        """,
        permissions: [.calendars],
        install: { host, plugin in
            plugin.installAPI(host, "calendar", CalendarRequest.methods) { call in
                let request = try CalendarRequest.parse(call)
                guard Permission.calendars.grant == .granted else { throw HostFailure(missingGrant(.calendars, "calendar")) }
                return .later(CalendarStore.queue) { CalendarStore.read(request) }
            }
        },
        topic: CapabilityTopic(type: "CalendarChange") { CalendarTopic($0) },
    )
}

enum CalendarStore {
    static let queue = DispatchQueue(label: "gary.calendar", qos: .userInitiated)
    private static var store: EKEventStore?

    static func request() {
        let store = EKEventStore()
        store.requestFullAccessToEvents { _, _ in _ = store }
    }

    static func read(_ request: CalendarRequest) -> JSON {
        let store = store ?? EKEventStore()
        Self.store = store
        switch request {
        case .calendars:
            return .array(store.calendars(for: .event).map { calendar in
                .object([
                    "id": .string(calendar.calendarIdentifier), "title": .string(calendar.title),
                    "color": .string(hex(calendar.color)), "source": .string(calendar.source?.title ?? ""),
                ])
            })
        case let .events(start, end):
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            return .array(events.sorted { ($0.startDate, $0.title ?? "") < ($1.startDate, $1.title ?? "") }.map { event in
                .object([
                    "id": .string(event.eventIdentifier ?? event.calendarItemIdentifier),
                    "calendar": .string(event.calendar.calendarIdentifier),
                    "title": .string(event.title ?? ""),
                    "start": .number((event.startDate.timeIntervalSince1970 * 1000).rounded()),
                    "end": .number((event.endDate.timeIntervalSince1970 * 1000).rounded()),
                    "allDay": .bool(event.isAllDay),
                    "location": event.location.flatMap { $0.isEmpty ? nil : JSON.string($0) } ?? .null,
                    "color": .string(hex(event.calendar.color)),
                ])
            })
        }
    }

    private static func hex(_ color: NSColor?) -> String {
        guard let color = color?.usingColorSpace(.sRGB) else { return "#808080" }
        return RGBA(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent).hex
    }
}

private final class CalendarTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private var count = 0
    private var observations: [Observation] = []
    private var accessTimer: Timer?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        observations.append(Observation(.default, .EKEventStoreChanged) { [weak self] in
            guard let self else { return }
            count += 1
            send(Trace("calendar"))
        })
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.send(Trace("calendar-access")) }
        RunLoop.main.add(timer, forMode: .common)
        accessTimer = timer
        observations.append(Observation { timer.invalidate() })
        send(Trace("calendar-start"))
    }

    private func send(_ trace: Trace) {
        guard Permission.calendars.grant == .granted else {
            publish(.object([
                "available": .bool(false), "reason": .string(missingGrant(.calendars, "calendar")), "count": .number(Double(count)),
            ]), trace)
            return
        }
        accessTimer?.invalidate()
        publish(.object(["available": .bool(true), "count": .number(Double(count))]), trace)
    }
}
