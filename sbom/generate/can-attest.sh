#!/usr/bin/env bash
# Decides whether the SBOM is attested and what the subject is; writes `attest` and `subject-path` to GITHUB_OUTPUT.
# The runner sets ACTIONS_ID_TOKEN_REQUEST_URL only when the job grants id-token: write.
# Env: ATTEST, ACTIONS_ID_TOKEN_REQUEST_URL, SUBJECT_PATH, SBOM, SUBJECT_NAME, SUBJECT_DIGEST.
set -uo pipefail
out=${GITHUB_OUTPUT:-/dev/stdout}

if [ "${ATTEST:-true}" != "true" ]; then
  echo "SBOM written to $SBOM; attestation is turned off (attest: false)."
  echo "attest=false" >> "$out"; exit 0
fi
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "SBOM written to $SBOM and not attested: the job does not grant id-token: write (and attestations: write)."
  echo "attest=false" >> "$out"; exit 0
fi
if [ -n "${SUBJECT_NAME:-}" ]; then
  if [ -z "${SUBJECT_DIGEST:-}" ]; then
    echo "::warning::subject-name needs subject-digest; the SBOM is not attested."
    echo "attest=false" >> "$out"; exit 0
  fi
  echo "attest=true" >> "$out"; echo "subject-path=" >> "$out"; exit 0
fi
echo "attest=true" >> "$out"
echo "subject-path=${SUBJECT_PATH:-$SBOM}" >> "$out"
