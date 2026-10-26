# Is the live KMS key policy the attestation gate this sample installed?
#
# Reads a key policy document on standard input and exits 0 only when all four hold:
#   * the ONLY allow anywhere in the policy that can reach a decrypt is AttestedDecryptOnly;
#   * AttestedDecryptOnly is bound to this role and carries BOTH pinned conditions;
#   * the PCR17 deny is on every principal, covers kms:Decrypt and carries this measurement;
#   * the PCR8:ServiceName deny is on every principal and covers kms:Decrypt.
#
# Used by scripts/setup.sh after it writes the policy and by scripts/changed-pod.sh before
# it starts the refused pod, from one file rather than copied into each: a denial means
# "the measurement was refused" only if the gate that produced it is the gate we believe is
# there, and two copies of this program would eventually stop agreeing about that.
#
# Arguments: --arg role <role ARN> --arg roleid <role unique id> --arg pcr17 <measurement>

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
# An ALLOW is dangerous if it grants any route to the protected value: Decrypt itself,
# ReEncryptFrom (re-wrap under an ungated key, then decrypt there), or CreateGrant (hand
# the ability to someone else).
def reaches_decrypt:
  action_matches("kms:decrypt") or action_matches("kms:reencryptfrom")
  or action_matches("kms:creategrant");

# A DENY only does its job here if it refuses Decrypt. One covering just ReEncryptFrom
# would leave a mismatched measurement refused by implicit deny, where the page shows an
# explicit one, so ReEncryptFrom must NOT satisfy this side.
def denies_decrypt: actions | any(action_matches("kms:decrypt"));

([.Statement[] | select(.Effect == "Allow") | actions[] | select(reaches_decrypt)]
  | length) as $allow_actions_reaching_decrypt
| ([.Statement[] | select(.Sid == "AttestedDecryptOnly")
    | select(.Effect == "Allow")
    # The one allow that reaches a decrypt has to be THIS statement. Counting
    # decrypt-reaching actions across the policy and finding one is not enough on its own:
    # the count would also be 1 if this statement had been cut back to, say,
    # kms:DescribeKey and an unconditional decrypt allow added elsewhere.
    | select(actions | any(reaches_decrypt))
    # The ARN or the role unique id: KMS stores the id when the put lands while the role is
    # still propagating. Both name this one role and nothing else.
    | select((.Principal.AWS | if type == "array" then . else [.] end)
             | . == [$role] or . == [$roleid])
    | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
    | select(.Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"]
             == "eks.amazonaws.com")
    # Exactly the two conditions the generator emits, and nothing hand-added beside them:
    # a third key in this block would be ANDed with these two, so the sample would be
    # gating on something it never predicted or printed.
    | select(.Condition | keys == ["StringEqualsIgnoreCase"])
    | select(.Condition.StringEqualsIgnoreCase | length == 2)
  ] | length) as $allows
| ([.Statement[] | select(.Sid == "DenyUnlessThePolicyMeasurementMatches")
    | select(.Effect == "Deny") | select(.Principal == "*")
    | select(denies_decrypt)
    | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == $pcr17)
    # One deny per register. The keys in a StringNotEqualsIgnoreCase block are ANDed too,
    # so a single deny listing two registers fires only when BOTH fail to match, and a
    # request matching one and not the other slips past it.
    | select(.Condition.StringNotEqualsIgnoreCase | length == 1)
  ] | length) as $pcr17_denies
| ([.Statement[] | select(.Sid == "DenyUnlessTheAttestationComesFromAnEKSSandbox")
    | select(.Effect == "Deny") | select(.Principal == "*")
    | select(denies_decrypt)
    | select(.Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"]
             == "eks.amazonaws.com")
    | select(.Condition.StringNotEqualsIgnoreCase | length == 1)
  ] | length) as $pcr8_denies
| $allow_actions_reaching_decrypt == 1
  and $allows == 1 and $pcr17_denies == 1 and $pcr8_denies == 1
