import re

with open('Testing/Suite/dr_lucky.txt', 'r') as f:
    orig = f.read().strip()

with open('Testing/TestTranscripts.swift', 'r') as f:
    swift = f.read()

match = re.search(r'static let dr_lucky_ground = """(.*?)"""', swift, re.DOTALL)
if match:
    swift_str = match.group(1).strip()
    if orig == swift_str:
        print("MATCH")
    else:
        print("DIFFERENCE")
else:
    print("NOT FOUND")
