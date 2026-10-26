# Does this key policy allow nothing that can reach a decrypt?
#
# Applied by scripts/setup.sh to the policy it is about to create the key with, before the
# key exists. The key's first policy is the gate with the one conditional allow taken out,
# so at that moment nothing at all may decrypt; this is what proves it, rather than trusting
# that the removal did what it looked like.
#
# The glob translation and the definition of "reaches a decrypt" are the ones gate.jq uses
# on the allow side, and the comments there explain both.

def action_matches($target):
  ascii_downcase as $glob
  | ($glob | test("^[a-z0-9:*?-]+$"))
    and ($target | test("^" + ($glob | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$"));

def reaches_decrypt:
  action_matches("kms:decrypt") or action_matches("kms:reencryptfrom")
  or action_matches("kms:creategrant");

([.Statement[] | select(.Effect == "Allow")
  | (.Action | if type == "array" then . else [.] end)[]
  | select(reaches_decrypt)] | length) == 0
