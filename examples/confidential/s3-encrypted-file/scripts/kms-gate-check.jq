# Is this KMS key policy the gate the sample installed?
#
#   jq -e --arg mode gate --arg role <role-arn> --arg roleid <role-id> \
#     --arg pcr17 <expected> -f scripts/kms-gate-check.jq kms-key-policy.live.json
#
#   jq -e --arg mode birth --arg role "" --arg roleid "" --arg pcr17 "" \
#     -f scripts/kms-gate-check.jq kms-key-policy.birth.json
#
# In birth mode, true when no Allow in the document can reach a decrypt at all. That is
# what setup.sh checks before it creates the key, so the key cannot exist, even for a
# moment, with a policy that would release the data key to anyone.
#
# In gate mode, true only when all four hold:
#   * exactly one Allow action anywhere in the policy can reach a decrypt;
#   * that one is AttestedDecryptOnly, whose principal block names this role and no other
#     principal of any type, and which carries both expected conditions;
#   * the PCR17 deny is there, on every principal, and still covers kms:Decrypt;
#   * the PCR8:ServiceName deny is there, on every principal, and still covers it too.
#
# Both setup.sh and changed-pod.sh read the live policy through this one file, so the two
# checks cannot drift apart. A denial only means "the measurement was refused" if the gate
# that produced it is the gate we believe is there: a second allow that reaches a decrypt,
# or a deny that has lost kms:Decrypt, would leave a mismatched measurement refused by
# implicit deny, which a page could not tell from the explicit deny it shows.

# Does this IAM action string match the named action? An IAM action is matched
# case-insensitively and anchored, with * standing for any run of characters and ? for one.
# Action names hold no other regular-expression metacharacter, so turning the two wildcards
# into their regex equivalents is the whole translation. Testing the glob this way, rather
# than listing prefixes, is what makes "kms:De*", "kms:*crypt" and "kms:Decryp?" count:
# each of them really does grant the action.
def action_matches($target):
  ascii_downcase as $glob
  # An IAM action holds only these characters. Anything else is not an action and grants
  # nothing, so it matches nothing: without this, a string such as "kms:.ecrypt" would
  # become a regex that matches kms:decrypt, and a Deny carrying it would be counted as
  # refusing a decrypt when under IAM it refuses nothing. It also keeps a stray bracket out
  # of the regex, which would otherwise make the test throw.
  | ($glob | test("^[a-z0-9:*?-]+$"))
    and ($target | test("^" + ($glob | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$"));
def actions: (.Action | if type == "array" then . else [.] end);

# The two sides ask different questions, and the difference matters.
#
# An ALLOW is dangerous if it grants any route to the data key: Decrypt itself,
# ReEncryptFrom (re-wrap under an ungated key, then decrypt there), or CreateGrant (hand
# the ability to someone else).
def reaches_decrypt:
  action_matches("kms:decrypt") or action_matches("kms:reencryptfrom")
  or action_matches("kms:creategrant");
# A DENY only does its job here if it refuses Decrypt. One covering just ReEncryptFrom
# would leave a mismatched measurement refused by implicit deny, so ReEncryptFrom must NOT
# satisfy this side.
def covers_decrypt: action_matches("kms:decrypt");
def denies_decrypt: actions | any(covers_decrypt);

def gate:
([.Statement[] | select(.Effect == "Allow") | actions[] | select(reaches_decrypt)]
  | length) as $allow_actions_reaching_decrypt
| ([.Statement[] | select(.Sid == "AttestedDecryptOnly")
    | select(.Effect == "Allow")
    # The one allow that reaches a decrypt has to be THIS statement. Counting
    # decrypt-reaching actions across the policy and finding one is not enough on its own:
    # the count would also be 1 if this statement had been cut back to, say,
    # kms:DescribeKey and an unconditional decrypt allow added elsewhere.
    | select(actions | map(ascii_downcase) | any(reaches_decrypt))
    # The ARN or the role unique id: KMS stores the id when the put lands while the role is
    # still propagating. Both name this one role and nothing else.
    #
    # "AWS" has to be the ONLY key in the principal block. Reading .Principal.AWS on its own
    # would pass a statement such as
    #   "Principal": {"AWS": "<the role>", "Service": "something.amazonaws.com"}
    # which grants the conditional allow to a second principal as well, and the page's claim
    # is that this one allow is bound to the pod's role.
    | select((.Principal | type) == "object")
    | select((.Principal | keys) == ["AWS"])
    | select((.Principal.AWS | if type == "array" then . else [.] end)
             | . == [$role] or . == [$roleid])
    | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
    | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"]
             == "eks.amazonaws.com")
  ] | length) as $allows
| ([.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches")
    | select(.Effect == "Deny") | select(.Principal == "*")
    | select(denies_decrypt)
    | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
    # One register per deny, and nothing else in the block. The keys in a
    # StringNotEqualsIgnoreCase block are ANDed, so a deny listing two registers fires only
    # when BOTH fail to match: a request matching one and not the other slips past it. That
    # merged form looks stronger than the two separate denies and is weaker, so it is
    # refused here rather than installed.
    | select((.Condition.StringNotEqualsIgnoreCase | keys)
             == ["kms:RecipientAttestation:PCR17"])
    | select((.Condition | keys) == ["StringNotEqualsIgnoreCase"])
  ] | length) as $pcr17_denies
| ([.Statement[] | select(.Sid == "DenyUnlessTheAttestationComesFromAnEKSSandbox")
    | select(.Effect == "Deny") | select(.Principal == "*")
    | select(denies_decrypt)
    | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"]
             == "eks.amazonaws.com")
    | select((.Condition.StringNotEqualsIgnoreCase | keys)
             == ["kms:RecipientAttestation:PCR8:ServiceName"])
    | select((.Condition | keys) == ["StringNotEqualsIgnoreCase"])
  ] | length) as $pcr8_denies
| $allow_actions_reaching_decrypt == 1
  and $allows == 1 and $pcr17_denies == 1 and $pcr8_denies == 1;

def no_allow_reaches_decrypt:
  ([.Statement[] | select(.Effect == "Allow") | actions[] | select(reaches_decrypt)]
    | length) == 0;

if $mode == "birth" then no_allow_reaches_decrypt
elif $mode == "gate" then gate
else error("kms-gate-check.jq needs --arg mode birth or --arg mode gate")
end
