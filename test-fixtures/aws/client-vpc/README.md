# Client VPC fixture

Builds a VPC of exactly the shape a client hands over
(`client-vpc-handoff-template.yaml` at the repo root): a routable `/27`
plus the `100.64.0.0/19` secondary CIDR, and per AZ an edge `/28` with a
private NAT, a compute `/21` and a backend `/26`. It also builds the
compute, edge and backend route tables, an S3 gateway endpoint and,
optionally, a Transit Gateway. It then writes the filled handoff to
`client-handoffs/aws/<env>/<name>.yaml`, as the client would return it.

The workspace factory treats all of this as client-owned and never changes
it. See CLAUDE.md §10 item #15.

## Demo

```bash
cd test-fixtures/aws/client-vpc
./demo.sh up      # VPC -> handoff -> request -> plan -> apply -> validate
./demo.sh down    # tear down the workspace, then the VPC
```

Or run the steps one at a time: `vpc`, `import`, `plan`, `apply`,
`teardown`, `vpc-down`. `./demo.sh` with no argument lists them, along
with the settings (`NAME`, `ENV`, `DBX_ACCOUNT`, `DBX_PROFILE`, `TGW`,
`AUTO_APPROVE`, ...).

`import` is the step a real handoff goes through too. It checks the file
against live AWS, read-only, then writes the request:

```bash
python resolver/import_client_handoff.py --handoff client-handoffs/aws/dev/<name>.yaml \
    --request-id REQ-0xxxx --submitted-by <you> --cost-center <cc>
```

## Notes

- **One fixture at a time.** State lives at the fixed key
  `fixtures/aws/client-vpc/terraform.tfstate` in `beng-tfstatefiles`.
- **Cost while it's up**: two private NAT gateways (about $0.045/hour
  each), plus the TGW and its attachment if `TGW=true`.
- **Clusters won't start.** The edge route table leads nowhere (or to a
  TGW with no hub behind it), and the TSA Databricks account has no
  PrivateLink, so classic compute can't reach the control plane. The
  workspace, Unity Catalog and validation all work. That's the same
  pipeline-mechanics scope as CLAUDE.md §8 milestone 32.
- Keep `primary_cidr` clear of `10.64.0.0/10` (the factory's isolated-VPC
  pool) and other VPCs in the account.
