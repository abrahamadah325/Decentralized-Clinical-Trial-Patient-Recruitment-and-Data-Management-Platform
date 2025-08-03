import { describe, it, expect, beforeEach } from "vitest"
import { createHash } from "crypto"

// Mock Clarity contract interactions
const mockAdverseEventsContract = {
  adverseEvents: new Map(),
  regulatoryReports: new Map(),
  eventFollowUps: new Map(),
  authorizedReporters: new Map(),
  regulatoryAuthorities: new Map(),
  nextEventId: 1,
  regulatoryReportingThreshold: 3, // Severe and above
}

// Constants
const SEVERITY_MILD = 1
const SEVERITY_MODERATE = 2
const SEVERITY_SEVERE = 3
const SEVERITY_LIFE_THREATENING = 4
const SEVERITY_FATAL = 5

const CAUSALITY_UNRELATED = 1
const CAUSALITY_UNLIKELY = 2
const CAUSALITY_POSSIBLE = 3
const CAUSALITY_PROBABLE = 4
const CAUSALITY_DEFINITE = 5

function generateHash(data) {
  return createHash("sha256").update(data).digest("hex")
}

function mockAuthorizeReporter(reporter, siteId, role) {
  mockAdverseEventsContract.authorizedReporters.set(reporter, {
    isAuthorized: true,
    siteId,
    role,
  })
}

function mockReportAdverseEvent(
    patientId,
    trialId,
    eventDescription,
    severity,
    causality,
    onsetDate,
    requiresUnblinding,
    reporter,
) {
  const eventId = mockAdverseEventsContract.nextEventId++
  const reporterAuth = mockAdverseEventsContract.authorizedReporters.get(reporter)
  
  if (!reporterAuth?.isAuthorized) throw new Error("ERR-NOT-AUTHORIZED")
  if (severity < SEVERITY_MILD || severity > SEVERITY_FATAL) throw new Error("ERR-INVALID-INPUT")
  if (causality < CAUSALITY_UNRELATED || causality > CAUSALITY_DEFINITE) throw new Error("ERR-INVALID-INPUT")
  if (onsetDate > Date.now()) throw new Error("ERR-INVALID-INPUT")
  
  const eventDescriptionHash = generateHash(eventDescription)
  const isSerious = severity >= SEVERITY_SEVERE
  
  mockAdverseEventsContract.adverseEvents.set(eventId, {
    patientId,
    trialId,
    eventDescriptionHash,
    severity,
    causality,
    onsetDate,
    resolutionDate: null,
    reporter,
    reportedAt: Date.now(),
    isSerious,
    requiresUnblinding,
  })
  
  // Auto-trigger regulatory reporting for serious events
  if (severity >= mockAdverseEventsContract.regulatoryReportingThreshold) {
    mockTriggerRegulatoryReport(eventId)
  }
  
  return eventId
}

function mockTriggerRegulatoryReport(eventId) {
  const event = mockAdverseEventsContract.adverseEvents.get(eventId)
  
  if (!event) throw new Error("ERR-EVENT-NOT-FOUND")
  if (mockAdverseEventsContract.regulatoryReports.has(eventId)) throw new Error("ERR-ALREADY-REPORTED")
  if (!event.isSerious) throw new Error("ERR-INVALID-INPUT")
  
  mockAdverseEventsContract.regulatoryReports.set(eventId, {
    reportDate: Date.now(),
    authority: "FDA",
    reportId: `AE-${eventId}`,
    status: "submitted",
    followUpRequired: true,
  })
  
  return true
}

function mockAddFollowUp(eventId, followUpId, description, outcomeChanged, newSeverity, newCausality, reporter) {
  const event = mockAdverseEventsContract.adverseEvents.get(eventId)
  const reporterAuth = mockAdverseEventsContract.authorizedReporters.get(reporter)
  
  if (!event) throw new Error("ERR-EVENT-NOT-FOUND")
  if (!reporterAuth?.isAuthorized) throw new Error("ERR-NOT-AUTHORIZED")
  
  const descriptionHash = generateHash(description)
  
  mockAdverseEventsContract.eventFollowUps.set(`${eventId}-${followUpId}`, {
    followUpDate: Date.now(),
    descriptionHash,
    reporter,
    outcomeChanged,
    newSeverity,
    newCausality,
  })
  
  // Update main event if outcome changed
  if (outcomeChanged) {
    if (newSeverity) event.severity = newSeverity
    if (newCausality) event.causality = newCausality
  }
  
  return true
}

function mockResolveEvent(eventId, resolutionDate, reporter) {
  const event = mockAdverseEventsContract.adverseEvents.get(eventId)
  const reporterAuth = mockAdverseEventsContract.authorizedReporters.get(reporter)
  
  if (!event) throw new Error("ERR-EVENT-NOT-FOUND")
  if (!reporterAuth?.isAuthorized) throw new Error("ERR-NOT-AUTHORIZED")
  if (resolutionDate < event.onsetDate) throw new Error("ERR-INVALID-INPUT")
  if (event.resolutionDate) throw new Error("ERR-INVALID-INPUT")
  
  event.resolutionDate = resolutionDate
  
  return true
}

describe("Adverse Events Contract", () => {
  beforeEach(() => {
    // Reset mock contract state
    mockAdverseEventsContract.adverseEvents.clear()
    mockAdverseEventsContract.regulatoryReports.clear()
    mockAdverseEventsContract.eventFollowUps.clear()
    mockAdverseEventsContract.authorizedReporters.clear()
    mockAdverseEventsContract.regulatoryAuthorities.clear()
    mockAdverseEventsContract.nextEventId = 1
  })
  
  describe("Event Reporting", () => {
    beforeEach(() => {
      mockAuthorizeReporter("reporter1", 1, "investigator")
    })
    
    it("should report mild adverse event", () => {
      const eventId = mockReportAdverseEvent(
          1,
          1,
          "Mild headache",
          SEVERITY_MILD,
          CAUSALITY_POSSIBLE,
          Date.now() - 1000,
          false,
          "reporter1",
      )
      
      expect(eventId).toBe(1)
      expect(mockAdverseEventsContract.adverseEvents.has(1)).toBe(true)
      
      const event = mockAdverseEventsContract.adverseEvents.get(1)
      expect(event.severity).toBe(SEVERITY_MILD)
      expect(event.isSerious).toBe(false)
      expect(event.reporter).toBe("reporter1")
    })
    
    it("should report severe adverse event and trigger regulatory report", () => {
      const eventId = mockReportAdverseEvent(
          1,
          1,
          "Severe allergic reaction",
          SEVERITY_SEVERE,
          CAUSALITY_PROBABLE,
          Date.now() - 1000,
          true,
          "reporter1",
      )
      
      expect(eventId).toBe(1)
      
      const event = mockAdverseEventsContract.adverseEvents.get(1)
      expect(event.severity).toBe(SEVERITY_SEVERE)
      expect(event.isSerious).toBe(true)
      expect(event.requiresUnblinding).toBe(true)
      
      // Should auto-trigger regulatory report
      expect(mockAdverseEventsContract.regulatoryReports.has(1)).toBe(true)
      
      const report = mockAdverseEventsContract.regulatoryReports.get(1)
      expect(report.authority).toBe("FDA")
      expect(report.status).toBe("submitted")
    })
    
    it("should reject unauthorized reporter", () => {
      expect(() =>
          mockReportAdverseEvent(1, 1, "Event", SEVERITY_MILD, CAUSALITY_POSSIBLE, Date.now(), false, "unauthorized"),
      ).toThrow("ERR-NOT-AUTHORIZED")
    })
    
    it("should reject invalid severity", () => {
      expect(() =>
          mockReportAdverseEvent(1, 1, "Event", 0, CAUSALITY_POSSIBLE, Date.now(), false, "reporter1"),
      ).toThrow("ERR-INVALID-INPUT")
      
      expect(() =>
          mockReportAdverseEvent(1, 1, "Event", 6, CAUSALITY_POSSIBLE, Date.now(), false, "reporter1"),
      ).toThrow("ERR-INVALID-INPUT")
    })
    
    it("should reject invalid causality", () => {
      expect(() => mockReportAdverseEvent(1, 1, "Event", SEVERITY_MILD, 0, Date.now(), false, "reporter1")).toThrow(
          "ERR-INVALID-INPUT",
      )
    })
    
    it("should reject future onset date", () => {
      expect(() =>
          mockReportAdverseEvent(
              1,
              1,
              "Event",
              SEVERITY_MILD,
              CAUSALITY_POSSIBLE,
              Date.now() + 10000,
              false,
              "reporter1",
          ),
      ).toThrow("ERR-INVALID-INPUT")
    })
  })
  
  describe("Follow-up Management", () => {
    beforeEach(() => {
      mockAuthorizeReporter("reporter1", 1, "investigator")
      mockReportAdverseEvent(
          1,
          1,
          "Initial event",
          SEVERITY_MODERATE,
          CAUSALITY_POSSIBLE,
          Date.now() - 1000,
          false,
          "reporter1",
      )
    })
    
    it("should add follow-up without outcome change", () => {
      const result = mockAddFollowUp(1, 1, "Patient feeling better", false, null, null, "reporter1")
      
      expect(result).toBe(true)
      expect(mockAdverseEventsContract.eventFollowUps.has("1-1")).toBe(true)
      
      const followUp = mockAdverseEventsContract.eventFollowUps.get("1-1")
      expect(followUp.outcomeChanged).toBe(false)
      expect(followUp.reporter).toBe("reporter1")
    })
    
    it("should add follow-up with severity change", () => {
      const result = mockAddFollowUp(1, 1, "Condition worsened", true, SEVERITY_SEVERE, null, "reporter1")
      
      expect(result).toBe(true)
      
      const followUp = mockAdverseEventsContract.eventFollowUps.get("1-1")
      expect(followUp.outcomeChanged).toBe(true)
      expect(followUp.newSeverity).toBe(SEVERITY_SEVERE)
      
      // Check that main event was updated
      const event = mockAdverseEventsContract.adverseEvents.get(1)
      expect(event.severity).toBe(SEVERITY_SEVERE)
    })
    
    it("should reject follow-up for non-existent event", () => {
      expect(() => mockAddFollowUp(999, 1, "Follow-up", false, null, null, "reporter1")).toThrow("ERR-EVENT-NOT-FOUND")
    })
    
    it("should reject unauthorized follow-up", () => {
      expect(() => mockAddFollowUp(1, 1, "Follow-up", false, null, null, "unauthorized")).toThrow("ERR-NOT-AUTHORIZED")
    })
  })
  
  describe("Event Resolution", () => {
    beforeEach(() => {
      mockAuthorizeReporter("reporter1", 1, "investigator")
      mockReportAdverseEvent(
          1,
          1,
          "Resolvable event",
          SEVERITY_MILD,
          CAUSALITY_POSSIBLE,
          Date.now() - 2000,
          false,
          "reporter1",
      )
    })
    
    it("should resolve event", () => {
      const resolutionDate = Date.now()
      const result = mockResolveEvent(1, resolutionDate, "reporter1")
      
      expect(result).toBe(true)
      
      const event = mockAdverseEventsContract.adverseEvents.get(1)
      expect(event.resolutionDate).toBe(resolutionDate)
    })
    
    it("should reject resolution before onset", () => {
      const event = mockAdverseEventsContract.adverseEvents.get(1)
      const invalidResolutionDate = event.onsetDate - 1000
      
      expect(() => mockResolveEvent(1, invalidResolutionDate, "reporter1")).toThrow("ERR-INVALID-INPUT")
    })
    
    it("should reject double resolution", () => {
      mockResolveEvent(1, Date.now(), "reporter1")
      
      expect(() => mockResolveEvent(1, Date.now(), "reporter1")).toThrow("ERR-INVALID-INPUT")
    })
  })
  
  describe("Regulatory Reporting", () => {
    beforeEach(() => {
      mockAuthorizeReporter("reporter1", 1, "investigator")
      mockReportAdverseEvent(
          1,
          1,
          "Severe event",
          SEVERITY_SEVERE,
          CAUSALITY_PROBABLE,
          Date.now() - 1000,
          false,
          "reporter1",
      )
    })
    
    it("should have auto-triggered regulatory report", () => {
      expect(mockAdverseEventsContract.regulatoryReports.has(1)).toBe(true)
      
      const report = mockAdverseEventsContract.regulatoryReports.get(1)
      expect(report.authority).toBe("FDA")
      expect(report.reportId).toBe("AE-1")
      expect(report.status).toBe("submitted")
      expect(report.followUpRequired).toBe(true)
    })
    
    it("should reject duplicate regulatory report", () => {
      expect(() => mockTriggerRegulatoryReport(1)).toThrow("ERR-ALREADY-REPORTED")
    })
  })
  
  describe("Authorization Management", () => {
    it("should authorize reporter", () => {
      mockAuthorizeReporter("newReporter", 2, "coordinator")
      
      expect(mockAdverseEventsContract.authorizedReporters.has("newReporter")).toBe(true)
      
      const reporter = mockAdverseEventsContract.authorizedReporters.get("newReporter")
      expect(reporter.isAuthorized).toBe(true)
      expect(reporter.siteId).toBe(2)
      expect(reporter.role).toBe("coordinator")
    })
  })
})
