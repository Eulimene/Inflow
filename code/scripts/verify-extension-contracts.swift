import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum ContractError: String, Error {
    case invalidReverseDomain = "EXT_ID_INVALID_REVERSE_DOMAIN"
    case invalidSemVer = "EXT_SEMVER_INVALID"
    case invalidHostReleaseVersion = "EXT_HOST_RELEASE_VERSION_INVALID"
    case duplicateComponentID = "EXT_COMPONENT_ID_DUPLICATE"
    case namespacePolicySetMismatch = "EXT_NAMESPACE_POLICY_SET_MISMATCH"
    case duplicateNamespacePolicy = "EXT_NAMESPACE_POLICY_DUPLICATE"
    case requiredAttributeUndeclared = "EXT_ATTRIBUTE_REQUIRED_UNDECLARED"
    case incoherentAttributeBounds = "EXT_ATTRIBUTE_BOUNDS_INCOHERENT"
    case allowedAttributeValueOutOfRange = "EXT_ATTRIBUTE_ALLOWED_VALUE_OUT_OF_RANGE"
    case attributeBindingMismatch = "EXT_ATTRIBUTE_BINDING_MISMATCH"
    case noncanonicalCapabilitySet = "EXT_CAPABILITY_SET_NONCANONICAL"
    case capabilitySetHashMismatch = "EXT_CAPABILITY_SET_HASH_MISMATCH"
    case marketComponentSetMismatch = "EXT_MARKET_COMPONENT_SET_MISMATCH"
    case noncanonicalDomainInput = "EXT_DOMAIN_INPUT_NONCANONICAL"
    case domainInputHashMismatch = "EXT_DOMAIN_INPUT_HASH_MISMATCH"
    case domainResolutionSetMismatch = "EXT_DOMAIN_RESOLUTION_SET_MISMATCH"
    case disallowedDomainVersion = "EXT_DOMAIN_RESOLUTION_VERSION_DISALLOWED"
    case invalidRevocationReplacement = "EXT_REVOKE_REPLACEMENT_INVALID"
}

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

let reverseDomainPattern = #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"#
let semVerPattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
let hostReleaseVersionPattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#
let sha256Pattern = #"^(?!0{64}$)[a-f0-9]{64}$"#

func object(_ value: Any?, _ context: String) throws -> [String: Any] {
    guard let result = value as? [String: Any] else {
        throw FixtureFailure(description: "\(context) must be an object")
    }
    return result
}

func array(_ value: Any?, _ context: String) throws -> [Any] {
    guard let result = value as? [Any] else {
        throw FixtureFailure(description: "\(context) must be an array")
    }
    return result
}

func string(_ value: Any?, _ context: String) throws -> String {
    guard let result = value as? String else {
        throw FixtureFailure(description: "\(context) must be a string")
    }
    return result
}

func integer(_ value: Any?, _ context: String) throws -> Int {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
        throw FixtureFailure(description: "\(context) must be an integer")
    }
    let doubleValue = number.doubleValue
    guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else {
        throw FixtureFailure(description: "\(context) must be an integer")
    }
    return number.intValue
}

func finiteNumber(_ value: Any?, _ context: String) throws -> Double {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite
    else {
        throw FixtureFailure(description: "\(context) must be a finite number")
    }
    return number.doubleValue
}

func boolean(_ value: Any?, _ context: String) throws -> Bool {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID()
    else {
        throw FixtureFailure(description: "\(context) must be a Boolean")
    }
    return number.boolValue
}

func matches(_ pattern: String, _ value: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range) else { return false }
    return match.range == range
}

func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

func utf16Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
}

func isStrictlySorted(_ values: [String], by areInIncreasingOrder: (String, String) -> Bool) -> Bool {
    guard values.count > 1 else { return true }
    for index in 1..<values.count where !areInIncreasingOrder(values[index - 1], values[index]) {
        return false
    }
    return true
}

func escapedJSONString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x08: result += "\\b"
        case 0x09: result += "\\t"
        case 0x0A: result += "\\n"
        case 0x0C: result += "\\f"
        case 0x0D: result += "\\r"
        case 0x22: result += "\\\""
        case 0x5C: result += "\\\\"
        case 0x00...0x1F: result += String(format: "\\u%04x", scalar.value)
        default: result.unicodeScalars.append(scalar)
        }
    }
    result += "\""
    return result
}

// The two v1 hash preimages contain only objects, arrays, strings, Booleans,
// null and integers. Rejecting non-integral numbers prevents this validator
// from claiming a partial implementation of the RFC 8785 number algorithm.
func canonicalJCS(_ value: Any) throws -> String {
    if value is NSNull { return "null" }
    if let text = value as? String { return escapedJSONString(text) }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else {
            throw FixtureFailure(description: "v1 contract hash preimage contains a non-integral number")
        }
        return number.stringValue
    }
    if let values = value as? [Any] {
        return "[" + (try values.map(canonicalJCS)).joined(separator: ",") + "]"
    }
    if let dictionary = value as? [String: Any] {
        let members = try dictionary.keys.sorted(by: utf16Less).map { key in
            escapedJSONString(key) + ":" + (try canonicalJCS(dictionary[key] as Any))
        }
        return "{" + members.joined(separator: ",") + "}"
    }
    throw FixtureFailure(description: "unsupported JCS value \(type(of: value))")
}

func sha256Hex(of value: Any) throws -> String {
    let canonical = try canonicalJCS(value)
    return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

struct SemVer {
    let original: String
    let core: [String]
    let prerelease: [String]?

    init?(_ value: String) {
        guard matches(semVerPattern, value), value.utf8.count <= 128 else { return nil }
        original = value
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let mainAndPre = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        core = mainAndPre[0].split(separator: ".").map(String.init)
        prerelease = mainAndPre.count == 2
            ? mainAndPre[1].split(separator: ".").map(String.init)
            : nil
    }
}

func compareDecimal(_ lhs: String, _ rhs: String) -> ComparisonResult {
    if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
}

func semVerPrecedence(_ lhs: String, _ rhs: String) -> ComparisonResult {
    guard let left = SemVer(lhs), let right = SemVer(rhs) else { return .orderedSame }
    for index in 0..<3 {
        let result = compareDecimal(left.core[index], right.core[index])
        if result != .orderedSame { return result }
    }
    switch (left.prerelease, right.prerelease) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case let (leftParts?, rightParts?):
        for index in 0..<min(leftParts.count, rightParts.count) {
            let leftPart = leftParts[index]
            let rightPart = rightParts[index]
            if leftPart == rightPart { continue }
            let leftNumeric = leftPart.allSatisfy(\.isNumber)
            let rightNumeric = rightPart.allSatisfy(\.isNumber)
            if leftNumeric && rightNumeric { return compareDecimal(leftPart, rightPart) }
            if leftNumeric != rightNumeric { return leftNumeric ? .orderedAscending : .orderedDescending }
            return utf8Less(leftPart, rightPart) ? .orderedAscending : .orderedDescending
        }
        if leftParts.count == rightParts.count { return .orderedSame }
        return leftParts.count < rightParts.count ? .orderedAscending : .orderedDescending
    }
}

func semVerTotalLess(_ lhs: String, _ rhs: String) -> Bool {
    let precedence = semVerPrecedence(lhs, rhs)
    if precedence != .orderedSame { return precedence == .orderedAscending }
    return utf8Less(lhs, rhs)
}

func strings(_ values: [Any], _ context: String) throws -> [String] {
    try values.enumerated().map { try string($0.element, "\(context)[\($0.offset)]") }
}

func validateAttributePolicy(_ input: [String: Any]) throws -> ContractError? {
    let properties = try object(input["properties"], "attribute properties")
    let required = try strings(try array(input["requiredProperties"], "requiredProperties"), "requiredProperties")
    if !Set(required).isSubset(of: Set(properties.keys)) {
        return .requiredAttributeUndeclared
    }

    for (name, rawPolicy) in properties {
        let policy = try object(rawPolicy, "policy \(name)")
        let kind = try string(policy["kind"], "policy kind")
        switch kind {
        case "string":
            let minimum = try integer(policy["minLength"], "minLength")
            let maximum = try integer(policy["maxLength"], "maxLength")
            if minimum > maximum { return .incoherentAttributeBounds }
            if let rawAllowed = policy["allowedValues"] {
                for value in try strings(try array(rawAllowed, "allowedValues"), "allowedValues") {
                    let count = value.unicodeScalars.count
                    if count < minimum || count > maximum { return .allowedAttributeValueOutOfRange }
                }
            }
        case "number":
            let minimum = try finiteNumber(policy["minimum"], "minimum")
            let maximum = try finiteNumber(policy["maximum"], "maximum")
            if minimum > maximum { return .incoherentAttributeBounds }
            if let rawAllowed = policy["allowedValues"] {
                for rawValue in try array(rawAllowed, "allowedValues") {
                    let value = try finiteNumber(rawValue, "allowed number")
                    if value < minimum || value > maximum { return .allowedAttributeValueOutOfRange }
                }
            }
        case "string-array":
            let maximum = try integer(policy["itemMaxLength"], "itemMaxLength")
            if let rawAllowed = policy["allowedValues"] {
                for value in try strings(try array(rawAllowed, "allowedValues"), "allowedValues")
                    where value.unicodeScalars.count > maximum
                {
                    return .allowedAttributeValueOutOfRange
                }
            }
        case "boolean": break
        default: throw FixtureFailure(description: "unknown attribute policy kind \(kind)")
        }
    }
    return nil
}

func validateNamespacePolicyBinding(_ input: [String: Any]) throws -> ContractError? {
    let namespaces = try strings(try array(input["syntaxNamespaces"], "syntaxNamespaces"), "syntaxNamespaces")
    let bindings = try array(input["attributeSchemas"], "attributeSchemas").map {
        try object($0, "attribute schema binding")
    }
    let bindingNamespaces = try bindings.map { try string($0["namespace"], "binding namespace") }
    if Set(bindingNamespaces).count != bindingNamespaces.count { return .duplicateNamespacePolicy }
    if Set(namespaces) != Set(bindingNamespaces) { return .namespacePolicySetMismatch }

    let components = try array(input["components"], "components").map { try object($0, "component") }
    let policies = try object(input["policiesByPath"], "policiesByPath")
    for binding in bindings {
        let path = try string(binding["path"], "binding path")
        let namespace = try string(binding["namespace"], "binding namespace")
        let digest = try string(binding["sha256"], "binding sha256")
        let size = try integer(binding["size"], "binding size")
        let matchesInventory = try components.contains { component in
            try string(component["path"], "component path") == path
                && string(component["sha256"], "component sha256") == digest
                && integer(component["size"], "component size") == size
        }
        guard matchesInventory,
              let rawPolicy = policies[path],
              try string(object(rawPolicy, "bound policy")["namespace"], "policy namespace") == namespace
        else {
            return .attributeBindingMismatch
        }
    }
    return nil
}

func validateComponentIDs(_ input: [String: Any]) throws -> ContractError? {
    let components = try array(input["components"], "components").map { try object($0, "component") }
    let identifiers = try components.map { try string($0["componentID"], "componentID") }
    return Set(identifiers).count == identifiers.count ? nil : .duplicateComponentID
}

func validateCapabilitySet(_ input: [String: Any]) throws -> ContractError? {
    let capabilitySet = try object(input["capabilitySet"], "capabilitySet")
    let exactKeys: Set<String> = ["schemaVersion", "requiredCapabilities", "optionalCapabilities", "componentCapabilities"]
    guard Set(capabilitySet.keys) == exactKeys,
          try integer(capabilitySet["schemaVersion"], "schemaVersion") == 1
    else { return .noncanonicalCapabilitySet }

    let required = try strings(try array(capabilitySet["requiredCapabilities"], "requiredCapabilities"), "requiredCapabilities")
    let optional = try strings(try array(capabilitySet["optionalCapabilities"], "optionalCapabilities"), "optionalCapabilities")
    guard isStrictlySorted(required, by: utf8Less),
          isStrictlySorted(optional, by: utf8Less),
          Set(required).isDisjoint(with: Set(optional))
    else { return .noncanonicalCapabilitySet }

    let components = try array(capabilitySet["componentCapabilities"], "componentCapabilities").map {
        try object($0, "component capability")
    }
    let componentIDs = try components.map { try string($0["componentID"], "componentID") }
    guard isStrictlySorted(componentIDs, by: utf8Less) else { return .noncanonicalCapabilitySet }
    for component in components {
        let keys: Set<String> = ["componentID", "kind", "imports", "syntaxNamespaces", "attributePolicies"]
        guard Set(component.keys) == keys else { return .noncanonicalCapabilitySet }
        let imports = try strings(try array(component["imports"], "imports"), "imports")
        let namespaces = try strings(try array(component["syntaxNamespaces"], "syntaxNamespaces"), "syntaxNamespaces")
        guard isStrictlySorted(imports, by: utf8Less), isStrictlySorted(namespaces, by: utf8Less) else {
            return .noncanonicalCapabilitySet
        }
        let policies = try array(component["attributePolicies"], "attributePolicies").map {
            try object($0, "attribute policy digest")
        }
        let policyNamespaces = try policies.map { policy -> String in
            guard Set(policy.keys) == Set(["namespace", "sha256"]) else {
                throw FixtureFailure(description: "attribute policy digest is not closed-world")
            }
            return try string(policy["namespace"], "attribute policy namespace")
        }
        guard isStrictlySorted(policyNamespaces, by: utf8Less) else { return .noncanonicalCapabilitySet }
    }

    let claimed = try string(input["claimedSHA256"], "claimed capability hash")
    return try sha256Hex(of: capabilitySet) == claimed ? nil : .capabilitySetHashMismatch
}

func validateMarketComponentBinding(_ input: [String: Any]) throws -> ContractError? {
    func tuple(_ value: Any, context: String) throws -> String {
        let component = try object(value, context)
        return try [
            string(component["componentID"], "componentID"),
            string(component["kind"], "component kind"),
            string(component["sha256"], "component sha256"),
            String(integer(component["size"], "component size")),
        ].joined(separator: "\u{0}")
    }
    let manifest = try array(input["manifestComponents"], "manifestComponents")
        .map { try tuple($0, context: "manifest component") }
    let resolved = try array(input["resolvedComponents"], "resolvedComponents")
        .map { try tuple($0, context: "resolved component") }
    guard Set(manifest).count == manifest.count,
          Set(resolved).count == resolved.count,
          Set(manifest) == Set(resolved)
    else { return .marketComponentSetMismatch }
    return nil
}

func componentKey(_ object: [String: Any]) throws -> String {
    try string(object["extensionID"], "extensionID") + "\u{0}" + string(object["componentID"], "componentID")
}

func validateDomainResolution(_ input: [String: Any]) throws -> ContractError? {
    let resolutionInput = try object(input["resolutionInput"], "resolutionInput")
    let requested = try array(resolutionInput["requestedComponents"], "requestedComponents").map {
        try object($0, "requested component")
    }
    let requestedKeys = try requested.map(componentKey)
    guard isStrictlySorted(requestedKeys, by: utf8Less) else { return .noncanonicalDomainInput }

    var allowedByKey: [String: Set<String>] = [:]
    for request in requested {
        let key = try componentKey(request)
        let allowed = try strings(try array(request["allowedVersions"], "allowedVersions"), "allowedVersions")
        guard allowed.allSatisfy({ SemVer($0) != nil }),
              isStrictlySorted(allowed, by: semVerTotalLess)
        else { return .noncanonicalDomainInput }
        allowedByKey[key] = Set(allowed)
    }

    let resolved = try array(input["resolvedComponents"], "resolvedComponents").map {
        try object($0, "resolved component")
    }
    let resolvedKeys = try resolved.map(componentKey)
    guard isStrictlySorted(resolvedKeys, by: utf8Less) else { return .noncanonicalDomainInput }
    guard Set(requestedKeys) == Set(resolvedKeys) else { return .domainResolutionSetMismatch }

    let inputAPIVersion = try string(resolutionInput["apiVersion"], "resolution input apiVersion")
    for component in resolved {
        let key = try componentKey(component)
        let version = try string(component["extensionVersion"], "resolved version")
        let apiVersion = try string(component["apiVersion"], "resolved apiVersion")
        guard allowedByKey[key]?.contains(version) == true, apiVersion == inputAPIVersion else {
            return .disallowedDomainVersion
        }
    }

    let claimed = try string(input["resolutionInputSHA256"], "resolution input hash")
    return try sha256Hex(of: resolutionInput) == claimed ? nil : .domainInputHashMismatch
}

func validateRevocationUpdate(_ input: [String: Any]) throws -> ContractError? {
    let target = try object(input["target"], "revocation target")
    let action = try string(target["requiredAction"], "requiredAction")
    if action != "update-required" {
        return target["replacementVersion"] is NSNull
            && target["replacementReleaseRecordSHA256"] is NSNull
            ? nil : .invalidRevocationReplacement
    }

    guard let replacementVersion = target["replacementVersion"] as? String,
          let replacementHash = target["replacementReleaseRecordSHA256"] as? String,
          matches(semVerPattern, replacementVersion),
          matches(sha256Pattern, replacementHash),
          replacementVersion != (try string(target["extensionVersion"], "revoked version")),
          !(input["replacementRecord"] is NSNull)
    else { return .invalidRevocationReplacement }

    let record = try object(input["replacementRecord"], "replacement record")
    let targetSequence = try integer(input["targetReleaseSequence"], "target release sequence")
    let recordIsValid = try string(record["extensionID"], "replacement extensionID")
        == string(target["extensionID"], "target extensionID")
        && string(record["extensionVersion"], "replacement extensionVersion") == replacementVersion
        && string(record["recordSHA256"], "replacement record hash") == replacementHash
        && integer(record["releaseSequence"], "replacement release sequence") > targetSequence
        && boolean(record["revoked"], "replacement revoked") == false
    return recordIsValid ? nil : .invalidRevocationReplacement
}

func evaluate(ruleID: String, input: [String: Any]) throws -> ContractError? {
    switch ruleID {
    case "reverse-domain":
        let value = try string(input["value"], "reverse-domain value")
        return matches(reverseDomainPattern, value) && value.utf8.count <= 160
            ? nil : .invalidReverseDomain
    case "semver-2.0.0":
        return SemVer(try string(input["value"], "SemVer value")) == nil ? .invalidSemVer : nil
    case "host-release-version":
        let value = try string(input["value"], "host release version")
        return matches(hostReleaseVersionPattern, value) && value.utf8.count <= 64
            ? nil : .invalidHostReleaseVersion
    case "component-id-uniqueness": return try validateComponentIDs(input)
    case "namespace-policy-binding": return try validateNamespacePolicyBinding(input)
    case "attribute-policy": return try validateAttributePolicy(input)
    case "capability-set": return try validateCapabilitySet(input)
    case "market-component-binding": return try validateMarketComponentBinding(input)
    case "domain-resolution": return try validateDomainResolution(input)
    case "revocation-update": return try validateRevocationUpdate(input)
    default: throw FixtureFailure(description: "unknown rule_id \(ruleID)")
    }
}

func validateCases(_ cases: [Any], expectingRejection: Bool, seenIDs: inout Set<String>) throws -> Int {
    var count = 0
    for rawCase in cases {
        let fixture = try object(rawCase, "fixture case")
        let identifier = try string(fixture["id"], "case id")
        guard seenIDs.insert(identifier).inserted else {
            throw FixtureFailure(description: "duplicate case id \(identifier)")
        }
        let ruleID = try string(fixture["rule_id"], "rule_id")
        let input = try object(fixture["input"], "case input")
        let expected = try object(fixture["expected"], "expected result")
        let outcome = try string(expected["outcome"], "expected outcome")
        let error = try evaluate(ruleID: ruleID, input: input)
        if expectingRejection {
            let expectedCode = try string(expected["error_code"], "expected error_code")
            guard outcome == "reject", error?.rawValue == expectedCode else {
                throw FixtureFailure(
                    description: "\(identifier) expected \(expectedCode), received \(error?.rawValue ?? "accept")"
                )
            }
        } else {
            guard outcome == "accept", error == nil else {
                throw FixtureFailure(
                    description: "\(identifier) expected accept, received \(error?.rawValue ?? "fixture error")"
                )
            }
        }
        count += 1
    }
    return count
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw FixtureFailure(description: "usage: verify-extension-contracts.swift CORPUS_JSON")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let corpus = try object(try JSONSerialization.jsonObject(with: data), "corpus")
    guard try integer(corpus["schema_version"], "schema_version") == 1,
          try string(corpus["contract_status"], "contract_status") == "frozen",
          try string(corpus["execution_evidence"], "execution_evidence") == "open"
    else {
        throw FixtureFailure(description: "corpus status must be frozen with future execution evidence open")
    }
    var identifiers: Set<String> = []
    let positiveCount = try validateCases(
        try array(corpus["positive_cases"], "positive_cases"),
        expectingRejection: false,
        seenIDs: &identifiers
    )
    let negativeCount = try validateCases(
        try array(corpus["negative_cases"], "negative_cases"),
        expectingRejection: true,
        seenIDs: &identifiers
    )
    print("verified \(positiveCount) positive and \(negativeCount) negative extension contract fixtures; ecosystem execution evidence remains OPEN")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
