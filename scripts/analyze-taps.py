#!/usr/bin/env python3
"""Summarize a local guided Watch recording; never sends data anywhere."""
import json
import math
import statistics
import sys


def quantile(values, fraction):
    values = sorted(values)
    return values[min(len(values)-1, int((len(values)-1)*fraction))] if values else 0


def magnitude(vector):
    return math.sqrt(sum(value*value for value in vector))


def analyze(path):
    with open(path) as handle:
        recording = json.load(handle)
    samples = recording["samples"]
    if len(samples) < 2:
        raise ValueError("Recording has fewer than two samples")
    low = None
    previous = None
    rows = []
    for sample in samples:
        now = sample["time"]
        acceleration = [sample["acceleration"][key] for key in "xyz"]
        rotation = magnitude([sample["rotation"][key] for key in "xyz"])
        if low is None:
            low = acceleration
        else:
            dt = now-previous
            weight = 1-math.exp(-dt/0.045)
            low = [old+(new-old)*weight for old, new in zip(low, acceleration)]
        pulse = magnitude([new-old for new, old in zip(acceleration, low)])
        rows.append({"time": now, "pulse": pulse, "rotation": rotation})
        previous = now
    start = samples[0]["time"]
    cues = recording.get("cueTimes", [])
    quiet = [row for row in rows if start+0.5 <= row["time"] <= start+2.5]
    intervals = [b["time"]-a["time"] for a, b in zip(samples, samples[1:])]
    result = {
        "device": recording.get("device"), "reason": recording.get("reason"),
        "samples": len(samples), "duration": round(samples[-1]["time"]-start, 3),
        "measuredHz": recording.get("measuredHz"), "medianInterval": statistics.median(intervals),
        "largestGap": max(intervals),
        "quiet": {"pulseP50": quantile([x["pulse"] for x in quiet], 0.5),
                  "pulseP95": quantile([x["pulse"] for x in quiet], 0.95),
                  "pulseP99": quantile([x["pulse"] for x in quiet], 0.99),
                  "rotationP95": quantile([x["rotation"] for x in quiet], 0.95)},
        "cues": []
    }
    for index, cue in enumerate(cues):
        end = cues[index+1] if index+1 < len(cues) else samples[-1]["time"]
        window = [row for row in rows if cue <= row["time"] < end]
        peak = max(window, key=lambda row: row["pulse"])
        result["cues"].append({
            "cue": index+1, "peakG": peak["pulse"], "delaySeconds": peak["time"]-cue,
            "rotationAtPeak": peak["rotation"], "maxRotation": max(row["rotation"] for row in window),
            "samplesAboveOriginalThreshold": sum(row["pulse"] >= 0.025 for row in window),
            "pulseP95": quantile([row["pulse"] for row in window], 0.95)
        })
    return result


if __name__ == "__main__":
    print(json.dumps(analyze(sys.argv[1]), indent=2))
