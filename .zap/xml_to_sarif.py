#!/usr/bin/env python3
"""Convert ZAP XML report to SARIF 2.1.0."""
import json
import sys
import xml.etree.ElementTree as ET

xml_path  = sys.argv[1] if len(sys.argv) > 1 else "zap-report.xml"
sarif_path = sys.argv[2] if len(sys.argv) > 2 else "zap-report.sarif"

try:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    results = []
    for alert in root.iter("alertitem"):
        name = alert.findtext("name", "unknown")
        desc = alert.findtext("desc", "")
        risk = alert.findtext("riskdesc", "")
        level = "error" if "High" in risk else "warning" if "Medium" in risk else "note"
        for inst in alert.iter("instance"):
            uri = inst.findtext("uri", "")
            results.append({
                "ruleId": name,
                "level": level,
                "message": {"text": f"{name}: {desc[:200]}"},
                "locations": [{"physicalLocation": {"artifactLocation": {"uri": uri}}}],
            })
    sarif = {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [{"tool": {"driver": {"name": "OWASP ZAP", "rules": []}}, "results": results}],
    }
    with open(sarif_path, "w") as f:
        json.dump(sarif, f)
    print(f"SARIF written: {len(results)} results → {sarif_path}")
except Exception as e:
    print(f"SARIF conversion failed: {e}", file=sys.stderr)
    sys.exit(1)
