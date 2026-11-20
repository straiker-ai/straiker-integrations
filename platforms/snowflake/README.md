# Snowflake

`setup.sh` connects one Snowflake account to Straiker. It creates (or reuses) up to three service
users, one per Straiker product, each with its own least-privilege role and its own key pair. With
Defend, it also creates by default a dedicated X-Small warehouse for Defend's trace reads (see
[Warehouse and cost](#warehouse-and-cost)); Discover and Ascend get no Straiker warehouse. It
prints the values to paste into the Straiker console. `teardown.sh` removes them.

The scripts run SQL through the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index)
(`snow sql`) with a connection you already have. They send nothing to Straiker and write nothing to
disk. Private keys are generated in memory with `openssl` and printed once. Only the public half
goes to Snowflake.

The setup is a script and not a `.sql` file for two reasons. It mints and holds the private keys,
and it is shipped and checksummed with the other release assets. `--dry-run` prints the whole SQL
script it would run. You can review that output or paste it into a Snowsight worksheet instead
(see [Without the Snowflake CLI](#without-the-snowflake-cli)).

## What this connects

| Product | What it does with this access |
| --- | --- |
| Discover | Inventories the Cortex Agents in the databases you name: each agent's spec, tools, orchestration model, and the roles granted on it. Also inventories the Snowflake-managed MCP servers, Cortex Search services and semantic views those agents use. User: `STRAIKER_DISCOVER_SVC`. Always created. |
| Ascend | Sends red-team test prompts to the Cortex Agents you choose, as a user with the rights of a typical user of those agents. User: `STRAIKER_ASCEND_SVC`, created only with `--ascend-agents`. |
| Defend | Trace monitoring only. Straiker reads each agent's conversation traces after the turn and scores them. Snowflake has no third-party guardrail hook (neither Cortex Agents nor Cortex AI Gateway calls an external policy), so Defend cannot block a request inline. User: `STRAIKER_DEFEND_SVC`, created only with `--defend`. |

Each product has its own user and key, so no key can sign in as two users. The stored Discover key
can never run an agent, and the stored Ascend key can never read traces.

### Why three service users

A Snowflake service user (`TYPE = SERVICE`) is a login for software, not a person. It has no
password, cannot open Snowsight and never gets an MFA prompt. It signs in only with its key pair.
Each Straiker user has its own role, holding only what its product needs.

The three are separate because they hold different kinds of access:

- **Discover** sees metadata only: which agents exist, what they are configured to do, and which
  roles can use them.
- **Defend** sees conversation content: your users' prompts, the agents' replies and their tool
  calls.
- **Ascend** can run agents. Their tools run for real, and every turn is billed to you.

Separate users let you turn on Discover alone, approve each product on its own, and revoke one
without touching the others (`DROP USER`, or [`teardown.sh`](#rotate-or-remove)). Because each has
its own key, a leaked Discover key can neither read conversations nor run agents.

Only Defend has a Straiker warehouse, because only its trace reads are queries. Discover runs only
`SHOW` and `DESCRIBE` statements, which need no warehouse. Ascend calls the Cortex Agents REST API,
which needs none either; the agents' tools run their SQL on the warehouses named in their
specifications, which you grant to Ascend with `--ascend-warehouses`.

**You run the setup once, as `ACCOUNTADMIN`.** Defend needs it, to allow unredacted trace reads and
to create the resource monitor that caps its warehouse. Discover and Ascend may need less (see
[Prerequisites](#prerequisites)). After that, Straiker needs no admin access.

## What it creates in your account

The grants below are least privilege. They come from a run on a live account (2026-11-18), in
which Discover also held grants it no longer gets (see
[Not yet verified live](#not-yet-verified-live)). "Cannot" means it was tried and refused. Names in angle brackets are your arguments. Each `<database>` row is repeated
for every database in `--databases`. Defend's `<warehouse>` is `STRAIKER_WH`, or the warehouse you
pass with `--warehouse`.

**Discover** (always): user `STRAIKER_DISCOVER_SVC` with role `STRAIKER_DISCOVER`

| Item | Where | Why |
| --- | --- | --- |
| Role `STRAIKER_DISCOVER` | Account | Holds everything below. |
| Service user `STRAIKER_DISCOVER_SVC` (`TYPE = SERVICE`, default role `STRAIKER_DISCOVER`, `DEFAULT_SECONDARY_ROLES = ()`, no default warehouse), granted the role | Account | The identity Straiker signs in as. A service user has no password and signs in with its key only. With no secondary roles, only its own role is active: a role granted to it later stays off unless it switches to it. |
| RSA public key in `RSA_PUBLIC_KEY` | The user | Key-pair sign-in. The private key is printed for Straiker and kept nowhere else. |
| `USAGE` on `<database>`, and on all its schemas (`ALL` and `FUTURE`) | Each database | Lets the role see objects in the database. |
| `MONITOR` on all agents (`ALL` and `FUTURE`) | Each database | Lists and describes agents and shows the roles granted on them, but cannot run them. Without it, an agent is invisible to `SHOW AGENTS`. |
| `MONITOR` on all Cortex Search services (`ALL` and `FUTURE`) | Each database | Describes a search tool's definition, and so the tables it is built from. It cannot query the service. |
| `REFERENCES` on all semantic views (`ALL` and `FUTURE`) | Each database | Reads a semantic view's base tables and columns but not its rows. With this, Straiker can tell when an agent can reach personal data. |
| `USAGE` on all MCP servers (`ALL` and `FUTURE`) | Each database | MCP servers have no read-only privilege. `USAGE` is the only way to list and describe them. It allows connecting but not calling a tool, because each tool needs its own grant. |

Discover **cannot** (measured): read any table, run an agent, call a tool or procedure, or read
conversation content. It has no warehouse, so it cannot run a query that uses compute.

**Defend** (only with `--defend`): user `STRAIKER_DEFEND_SVC` with role `STRAIKER_DEFEND_MONITOR`

| Item | Where | Why |
| --- | --- | --- |
| Role `STRAIKER_DEFEND_MONITOR` and service user `STRAIKER_DEFEND_SVC` (as above, own key, default warehouse `<warehouse>`) | Account | A separate identity, because conversation content (prompts, replies, tool inputs and outputs) is a bigger grant than metadata. |
| `USAGE` on warehouse `<warehouse>` | Warehouse | Runs the trace reads, the only Straiker queries that need a warehouse. |
| `USAGE` on `<database>` and its schemas, `MONITOR` on all agents (`ALL` and `FUTURE`) | Each database | Required to read an agent's traces with `SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS`. |
| `READ UNREDACTED AI OBSERVABILITY EVENTS TABLE` | Account | Without it, traces carry metadata only. Prompts, replies and tool data are redacted, so Defend has nothing to score. |

Defend **cannot** (measured): read any table or run an agent.

**Defend's warehouse** (only with `--defend`, unless you pass `--warehouse`)

| Item | Where | Why |
| --- | --- | --- |
| Warehouse `STRAIKER_WH`: `WAREHOUSE_SIZE = XSMALL`, `AUTO_SUSPEND = 60`, `AUTO_RESUME = TRUE`, `INITIALLY_SUSPENDED = TRUE` | Account | Runs Defend's trace reads. Dedicated, so it suspends 60 seconds after Straiker's last query. Owned by the admin role; only `STRAIKER_DEFEND_MONITOR` gets `USAGE` on it. |
| Resource monitor `STRAIKER_RM`: `CREDIT_QUOTA = 100` (`--credit-quota`), `FREQUENCY = MONTHLY`, notify at 80%, suspend at 100% | Assigned to `STRAIKER_WH` | Caps what the warehouse can spend in a month. See [Warehouse and cost](#warehouse-and-cost). |

Both are created with `IF NOT EXISTS`, so an existing `STRAIKER_WH` keeps its size and
auto-suspend and an existing `STRAIKER_RM` keeps its quota; the script only assigns `STRAIKER_RM` to
`STRAIKER_WH`. With `--connection`, the script compares an existing one with the settings above and prints a
warning and the `ALTER` statement when they differ. It stops if `STRAIKER_WH` already has a
different resource monitor, because assigning `STRAIKER_RM` would replace it. Pass
`--warehouse STRAIKER_WH` to use that warehouse as it is. A run without `--defend` creates no
warehouse and no resource monitor.

**Ascend** (only with `--ascend-agents`): user `STRAIKER_ASCEND_SVC` with role `STRAIKER_ASCEND`

| Item | Where | Why |
| --- | --- | --- |
| Role `STRAIKER_ASCEND` and service user `STRAIKER_ASCEND_SVC` (as above, own key, no default warehouse) | Account | The red-team identity. Its REST calls to the agents need no warehouse. |
| `USAGE` on each `--ascend-warehouses` warehouse | Warehouses | The warehouses the agents' tools run their SQL on. A Cortex Analyst, procedure or function tool names one as its `execution_environment` (`DESCRIBE AGENT <agent>` shows it in `agent_spec`, under `tool_resources`), and runs on it with the caller's rights: without `USAGE`, that tool fails for Ascend. Cortex Search tools need none. |
| `USAGE` on the database and schema of every object below | Those databases and schemas | Needed to reach the objects. |
| `USAGE` on each agent in `--ascend-agents` | Agents | Lets Ascend prompt the agent. |
| `SELECT` on each `--ascend-tables` table and `--ascend-views` view | Tables, views | Agents answer with the caller's own data rights. |
| `SELECT` on each `--ascend-semantic-views` semantic view | Semantic views | Needed for Cortex Analyst tools. |
| `USAGE` on each `--ascend-search-services` service | Cortex Search services | Needed for search tools. |
| `USAGE` on each `--ascend-procedure` and `--ascend-function` | Procedures, functions | Needed for custom (generic) tools. |
| Each role in `--ascend-inherit-roles`, granted to `STRAIKER_ASCEND` | Role hierarchy | Ascend can test as an existing group of users and does not need a grant for each object. Admin roles are refused. |

Ascend **cannot** (measured): do anything outside the agents and objects it is granted.

The scripts never grant `MANAGE GRANTS`, an admin role (`ACCOUNTADMIN`, `SECURITYADMIN`, `SYSADMIN`,
`USERADMIN`, `ORGADMIN`) or ownership of anything. Discover and Defend get no `SELECT` on any table
or view, and no `USAGE` on any agent. Straiker checks this when it verifies the connection. It
fails verification if the Discover role chain holds an admin role, `USAGE` or ownership of an
agent, ownership of any object, or `SELECT` on any table or view. Do not grant other roles to
these users.

### Warehouse and cost

Only Defend's trace reads need a running warehouse. Discover runs only `SHOW` and `DESCRIBE`
statements, which Snowflake answers without a warehouse, so **a Discover-only setup creates no
warehouse and costs no warehouse credits**. Ascend's REST calls need none either; its probes are
billed as agent turns, and its agents' tools run on their own warehouses (below). Each Defend poll
wakes the warehouse, and Snowflake bills at least 60 seconds every time a warehouse resumes, then
by the second until it auto-suspends. An X-Small warehouse costs 1 credit per hour of running.

| Warehouse Straiker uses | Credits a day | Why |
| --- | --- | --- |
| A shared warehouse with Snowflake's default `AUTO_SUSPEND = 600`, when nothing else keeps it running | About **16** on X-Small, more on a larger size | Polled every 15 minutes, each wake keeps it up about 10 minutes, so it runs most of the day. |
| The dedicated X-Small `STRAIKER_WH` with `AUTO_SUSPEND = 60` | About **0.4 to 1.6** | Each wake bills about the 60-second minimum, for 24 to 96 wakes a day. |

That is why, with `--defend`, the script creates `STRAIKER_WH` by default and makes it the Defend
user's default warehouse. The Straiker console's Defend setup SQL creates the same warehouse when
you leave its **Defend warehouse** field empty.

**The credit cap.** `STRAIKER_RM` limits `STRAIKER_WH` to 100 credits per monthly period, counted
from the day it was created. At 1.6 credits a day, Defend's polling uses about 50 credits a month,
so 100 leaves room for more agents and catch-up reads. An X-Small left running for a whole month
would use about 744. Change the cap with `--credit-quota N` when you first run the script, or
later with `ALTER RESOURCE MONITOR STRAIKER_RM SET CREDIT_QUOTA = N;`.

At 80% Snowflake sends a notification to the account administrators who enabled resource monitor
notifications. At 100% it **suspends** `STRAIKER_WH` (`SUSPEND` lets running queries finish). We
chose to suspend because the warehouse is Straiker's alone. Reaching the cap means something is
wrong, and a hard cap lets you approve Straiker's warehouse spend in advance. The cost of that
choice: while the warehouse is suspended, Defend stops reading traces, until the next period or
until you raise the quota. Discover is unaffected: it uses no warehouse. If monitoring must never
stop, make the monitor notify only:

```sql
ALTER RESOURCE MONITOR STRAIKER_RM SET TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO NOTIFY;
```

A resource monitor counts warehouse credits only. Cortex Agent turns (Ascend's probes) are billed as
AI services credits, which `STRAIKER_RM` neither counts nor stops, and the SQL their tools run is
billed to the tools' own warehouses (`--ascend-warehouses`), not to `STRAIKER_WH`. Creating a
resource monitor needs `ACCOUNTADMIN`, so with `--defend` and without `--warehouse` the script
refuses another `--admin-role`.

**To give Defend your own warehouse**, pass `--warehouse NAME` with `--defend`. The script uses it
as it is, creates no resource monitor, and prints a warning recommending `AUTO_SUSPEND = 60`. With
`--connection` it looks the setting up and warns only when it is longer than 60 seconds or off.
Without a connection it cannot check, so it always warns. To follow the recommendation:

```sql
ALTER WAREHOUSE <warehouse> SET AUTO_SUSPEND = 60;
```

A shorter auto-suspend also applies to everything else that runs on that warehouse, which then
loses its cache sooner. If that matters, use the dedicated warehouse.

### Before you run it

- **Ascend runs real tools, and you pay for each probe.** A Cortex Agent runs its tools with the
  caller's rights, so write tools run for real during a red-team run. A procedure that creates a
  ticket creates real tickets. If the writes matter, point Ascend at a test copy of the agent or
  give it a role without write access. Each probe is a billed agent turn: about **0.05 credits**
  with the default orchestration model (measured). It is billed to your Snowflake account.
- **Give Ascend the rights of the users you are worried about, and never an admin role.** If
  Ascend has fewer rights than real users, it tests a weaker agent than the one in production. If
  it has more, it finds risks real users cannot reach.
- **Name the warehouses Ascend's tools run on.** Ascend gets no warehouse of its own. Each Cortex
  Analyst, procedure or function tool runs on the warehouse in its `execution_environment`, which
  `DESCRIBE AGENT <agent>` shows in `agent_spec`, under `tool_resources`. Pass each one with
  `--ascend-warehouses`. Without it, those tools fail for Ascend and it tests less than real users
  reach. The script warns when you pass none.
- **Rate limit.** Your account shares one limit of **1,000 requests per minute** across all its
  agents, and Ascend's probes count against it.
- **New databases need a re-run.** `MONITOR` on agents is granted per database. An agent in a
  database without the grant is invisible to Discover and Defend. Snowflake has no account-wide
  read-only grant on agents, and `MANAGE GRANTS` would show every agent but is an admin
  privilege, so the scripts do not ask for it. The `FUTURE` grants cover new agents in databases
  you already listed. When agents appear in a new database, re-run `setup.sh` with that database
  added to `--databases`. A re-run keeps the existing keys.
- **Schema-level future grants override these grants.** If a schema already has its own future
  grants for agents (or for search services, semantic views or MCP servers), Snowflake ignores
  database-level future grants of that type in that schema. New objects there need a re-run, or a
  matching schema-level grant.
- **Anything granted to `PUBLIC` is reachable by these users too.** For example, an agent with
  `USAGE` granted to `PUBLIC` could be run by the Discover user.
- **Network policies.** If an account- or user-level network policy applies to these users, it
  must allow Straiker's egress addresses. Key-pair sign-in does not itself need a network policy
  (measured). Straiker connects over the public internet to `*.snowflakecomputing.com`. Private
  connectivity (PrivateLink) is not supported.

## Prerequisites

- [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/installation/installation)
  (`snow`) with a working connection: `snow connection add`, then `snow connection test -c <name>`.
  You also need `openssl` (LibreSSL on macOS works) and [`jq`](https://jqlang.org/download/), and
  Bash 3.2 or later (the macOS default works).
- The connection's user can use **`ACCOUNTADMIN`**. That is the role the measured run used, the
  scripts' default, and the only role Straiker has verified. Defend needs it: Straiker has only
  granted `READ UNREDACTED AI OBSERVABILITY EVENTS TABLE` as `ACCOUNTADMIN`, and only
  `ACCOUNTADMIN` can create the `STRAIKER_RM` resource monitor, so with `--defend` and without
  `--warehouse` the script refuses another role.
- A narrower role for Discover and Ascend (from Snowflake's documentation, not verified by
  Straiker): `SECURITYADMIN` should be enough. It can create users and roles (it inherits
  `USERADMIN`), and its `MANAGE GRANTS` privilege lets it grant privileges on any object. Snowflake
  documents database-level `FUTURE` grants as needing `MANAGE GRANTS`. `USERADMIN` with a database
  owner is therefore not enough: the owner can grant only on objects its role owns, so not on agents
  or services another role created, and cannot make the `FUTURE` grants. Pass the role with
  `--admin-role`. If a grant is refused, the script stops before setting any key; re-run as
  `ACCOUNTADMIN`.
- The databases already exist, and so does Defend's warehouse if you pass `--warehouse`. For
  Ascend, the agents, the objects their tools use and the warehouses those tools run on already
  exist.
- Edition and region (from Snowflake's documentation, not verified by Straiker):
  - Cortex Agents must be available in your account's region, or cross-region inference must be
    enabled.
  - Service users and key-pair authentication work on every edition.
- The account identifier must be in `<org>-<account>` form. Straiker does not accept account
  locators (`xy12345.us-east-2.aws`) or PrivateLink hosts.

## Run it

Download a pinned release, verify its checksum, then run. Never run a copy from `main`.

```bash
VERSION=v0.1.0   # the latest release: https://github.com/straiker-ai/straiker-integrations/releases
BASE=https://github.com/straiker-ai/straiker-integrations/releases/download/$VERSION
curl -fsSLO "$BASE/snowflake-setup.sh"
curl -fsSLO "$BASE/SHA256SUMS"
grep ' snowflake-setup.sh$' SHA256SUMS | shasum -a 256 -c -
chmod +x snowflake-setup.sh

# See every change first. With --connection, read-only lookups run so the plan reflects
# existing users and keys. Nothing is changed and no key is created.
./snowflake-setup.sh --dry-run --connection my_admin \
  --databases AI_APPS,SALES_DB --defend \
  --ascend-agents AI_APPS.SUPPORT.SUPPORT_AGENT \
  --ascend-warehouses SUPPORT_WH \
  --ascend-tables AI_APPS.SUPPORT.TICKETS \
  --ascend-search-services AI_APPS.SUPPORT.KB_SEARCH \
  --ascend-procedure 'AI_APPS.SUPPORT.CREATE_TICKET(NUMBER, VARCHAR)'

# Apply.
./snowflake-setup.sh --connection my_admin \
  --databases AI_APPS,SALES_DB --defend \
  --ascend-agents AI_APPS.SUPPORT.SUPPORT_AGENT \
  --ascend-warehouses SUPPORT_WH \
  --ascend-tables AI_APPS.SUPPORT.TICKETS \
  --ascend-search-services AI_APPS.SUPPORT.KB_SEARCH \
  --ascend-procedure 'AI_APPS.SUPPORT.CREATE_TICKET(NUMBER, VARCHAR)'
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `--connection NAME` | required (optional with `--dry-run`) | Snowflake CLI connection to run the SQL with. A dry run without it assumes no Straiker user exists yet. |
| `--databases DB[,DB...]` | required | Every database that holds Cortex Agents. Discover and Defend see agents only in these. |
| `--defend` | off | Create the Defend trace-monitoring user and, unless `--warehouse` is given, its `STRAIKER_WH`. |
| `--warehouse NAME` | `STRAIKER_WH`, created | With `--defend` only: an existing warehouse for Defend's trace reads, instead of the dedicated `STRAIKER_WH`. It becomes the Defend user's default warehouse. See [Warehouse and cost](#warehouse-and-cost). |
| `--credit-quota N` | `100` | With `--defend` only: monthly credit quota of `STRAIKER_RM`. Not with `--warehouse`. |
| `--ascend-agents DB.SCHEMA.AGENT[,...]` | none | Agents Ascend may test. Creates the Ascend user. Every other `--ascend-*` option needs it. |
| `--ascend-tables FQN[,...]` | none | Tables the agents read (`SELECT`). |
| `--ascend-views FQN[,...]` | none | Views the agents read (`SELECT`). |
| `--ascend-semantic-views FQN[,...]` | none | Semantic views behind their Cortex Analyst tools (`SELECT`). |
| `--ascend-search-services FQN[,...]` | none | Cortex Search services they query (`USAGE`). |
| `--ascend-procedure 'DB.SCHEMA.NAME(TYPE, ...)'` | none | A procedure tool, with its argument types (`USAGE`). Repeat for each. |
| `--ascend-function 'DB.SCHEMA.NAME(TYPE, ...)'` | none | A function tool (`USAGE`). Repeat for each. |
| `--ascend-warehouses WH[,...]` | none | The warehouses the agents' tools run on (`USAGE`): each tool's `execution_environment` warehouse, from `DESCRIBE AGENT`. Ascend has no other warehouse. |
| `--ascend-inherit-roles ROLE[,...]` | none | Existing roles to grant to `STRAIKER_ASCEND`, so Ascend tests as those users. Admin roles are refused. A role that itself inherits an admin role is not detected here, but Straiker's verification fails on it. |
| `--admin-role ROLE` | `ACCOUNTADMIN` | Role that runs the SQL. |
| `--discover-user NAME` | `STRAIKER_DISCOVER_SVC` | Discover user name. |
| `--defend-user NAME` | `STRAIKER_DEFEND_SVC` | Defend user name. |
| `--ascend-user NAME` | `STRAIKER_ASCEND_SVC` | Ascend user name. |
| `--rotate-keys` | off | Give users that already have a key a new one. See [Rotate or remove](#rotate-or-remove). |
| `--dry-run` | off | Print the SQL that would run. Change nothing and create no key. |

All names must be unquoted Snowflake identifiers (letters, digits, `_` and `$`, not starting with a
digit), and they are upper-cased. The role names are fixed: `STRAIKER_DISCOVER`,
`STRAIKER_DEFEND_MONITOR` and `STRAIKER_ASCEND`, and so are `STRAIKER_WH` and `STRAIKER_RM`. If you
have an object with a quoted or mixed-case name, grant it by hand, in the form the dry run prints.

The script is idempotent. Re-running reuses the roles and users and repeats the grants, which
Snowflake treats as no-ops. A user that already has a key **keeps it**, so a re-run to add a
database does not change what Straiker holds. Keys are set last, after every grant succeeded. If a
grant fails, the script stops before that point and Straiker is never given a key it cannot use.

The private keys are printed once, to stdout only. Do not redirect them to a file or paste them
into tickets or chat.

### Without the Snowflake CLI

You can do the same setup by hand in a Snowsight worksheet:

1. Run `./snowflake-setup.sh --dry-run` with your arguments, without `--connection`. Paste the
   printed SQL into a worksheet, except the final `ALTER USER ... SET RSA_PUBLIC_KEY` lines, and
   run it as `ACCOUNTADMIN`.
2. Generate one key pair per user on your own machine. Use a fresh pair for each user, and never
   reuse one key for two users:

   ```bash
   umask 077
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out straiker_discover.p8
   openssl pkey -in straiker_discover.p8 -pubout -out straiker_discover.pub
   ```

   `straiker_discover.p8` is an unencrypted PKCS#8 private key (`-----BEGIN PRIVATE KEY-----`),
   which is the form Straiker accepts. It stays with you until you paste it into Straiker. Delete it
   afterwards.
3. Set each public key, without its `BEGIN`/`END` lines and line breaks:

   ```sql
   ALTER USER STRAIKER_DISCOVER_SVC SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
   ```

   To check that it took, run `DESC USER STRAIKER_DISCOVER_SVC`. `RSA_PUBLIC_KEY_FP` should match
   the output of `openssl pkey -pubin -in straiker_discover.pub -outform DER | openssl dgst -sha256 -binary | openssl enc -base64`.

### From the Straiker console

The Straiker console runs the same setup without the Snowflake CLI, and generates the keys for you:

1. In Straiker, go to **Add Agent Platform**, then **Snowflake**, and enter your account identifier.
   `acme-prod`, `acme.prod` and a Snowsight link all work.
2. In the **Discover** section, click **Generate the Discover key pair**. Your browser makes the key pair. The
   console shows setup SQL with the user name and the **public** key filled in. The **private** key
   is never shown; it is sent to Straiker once, when you click **Connect**.
3. Copy that SQL into a Snowsight worksheet and run it as `ACCOUNTADMIN`. Replace `<DATABASE>` with
   each database that holds agents first. Discover's SQL creates no warehouse.
4. To add Ascend or Defend, tick **Allow Ascend to send test prompts to Cortex Agents** or
   **Monitor Cortex Agent conversations with Straiker Defend**. Each opens its own
   section, with its own key pair and its own SQL to run the same way.
   - Ascend's SQL asks for `<TOOL_WAREHOUSE>`: the warehouse each of the agent's tools runs on,
     which `DESCRIBE AGENT` shows as the `execution_environment` under `tool_resources`. Repeat
     the line for each warehouse, or delete it if the agent only uses Cortex Search.
   - Defend's section has a **Defend warehouse** field. Leave it empty to have Defend's SQL create
     `STRAIKER_WH` and its credit cap, as the script does, or enter an existing warehouse.
5. Click **Connect**. Straiker signs in as each user and checks it is not over-privileged. It
   refuses an admin role on any of them, and table reads or the right to run agents on the Discover
   user. It then reports how many agents it sees and in which databases, with next steps for
   anything missing.

### Not yet verified live

The grants come from a run on a live account (2026-11-18). The scripts around them have been
tested against a stub of the Snowflake CLI, but not yet against a live account:

- The narrower grants since that run. The 2026-11-18 run also gave Discover the four `SNOWFLAKE`
  metadata database roles and a warehouse. It is not yet measured that Discover's sweep works
  with only the grants above and no warehouse, nor that Ascend's REST calls work with no default
  warehouse.
- The `snow sql` calls (`--connection`, `--role`, `--format json`, `--stdin`) and the parsing of
  `SHOW USERS`, `DESC USER`, `SHOW WAREHOUSES`, `SHOW RESOURCE MONITORS` and the account lookup.
- The `CREATE WAREHOUSE`, `CREATE RESOURCE MONITOR` and `ALTER WAREHOUSE ... SET RESOURCE_MONITOR`
  statements, and the costs in [Warehouse and cost](#warehouse-and-cost), which are worked out from
  Snowflake's billing rules rather than measured.
- Rotation into `RSA_PUBLIC_KEY_2`.
- Admin roles other than `ACCOUNTADMIN`, such as `SECURITYADMIN` for Discover and Ascend.
- Ascend signing in with a key pair. The measured prototype signed Ascend in with a programmatic
  access token. Snowflake documents key-pair sign-in for its REST APIs. It is not yet confirmed
  that the agent run and thread endpoints accept it.

If a step fails, the script prints Snowflake's error and stops. Fix the cause and re-run.

## Values to paste into Straiker

In the Straiker console's Snowflake onboarding form. The script prints these in the form's order.
The text in brackets on each label is the field name.

| Console field | Value |
| --- | --- |
| Account | `Account` line: `<org>-<account>`, lower-cased |
| Discover user | `discover_user` |
| Discover private key | `discover_private_key`: the whole PEM, including its `BEGIN` and `END` lines |
| Allow Ascend to send test prompts to Cortex Agents | Tick it only if you ran with `--ascend-agents` |
| Ascend user | `ascend_user` |
| Ascend private key | `ascend_private_key` |
| Monitor Cortex Agent conversations with Straiker Defend | Tick it only if you ran with `--defend` |
| Defend warehouse | `Defend warehouse` line. Leave it empty for `STRAIKER_WH`: it is the Defend user's default warehouse, which Straiker uses when the field is empty. With `--warehouse`, enter that warehouse |
| Defend user | `defend_user` |
| Defend private key | `defend_private_key` |

If a user already had a key, the output says `unchanged` for it. Straiker keeps the key it already
holds. Straiker accepts only unencrypted PKCS#8 RSA keys of 2048 bits or more.

## Rotate or remove

**Rotate**: re-run `setup.sh` with the same arguments plus `--rotate-keys`. Snowflake gives each
user two key slots, so the new key goes into the free one (`RSA_PUBLIC_KEY_2`, or
`RSA_PUBLIC_KEY`), and the old key keeps working in the meantime. Paste the new private key on
the Snowflake integration's edit page in Straiker. Then run the printed
`ALTER USER <user> UNSET RSA_PUBLIC_KEY` (or `RSA_PUBLIC_KEY_2`) to retire the old one. If a user
already has two keys, the script stops. Unset the one Straiker does not use, then re-run. To find
it, compare the fingerprints in `DESC USER <user>` against the ones the script printed.

**Remove**: download `snowflake-teardown.sh` from the same release and verify it the same way.

```bash
./snowflake-teardown.sh --dry-run --connection my_admin
./snowflake-teardown.sh --connection my_admin
```

It lists the Straiker users and roles it found and asks you to type `delete` (or pass `--yes`). It
then drops the users, which also removes their keys, so Straiker loses access at once. Then it
drops the roles `STRAIKER_DISCOVER`, `STRAIKER_DEFEND_MONITOR` and `STRAIKER_ASCEND`, which
removes the grants made to them. Last, it drops Defend's `STRAIKER_WH` if the setup created it (it
carries the setup's comment, which the console's Defend setup SQL sets too), and `STRAIKER_RM` with it unless
another warehouse uses that monitor or it is the account's monitor. A `STRAIKER_WH` the setup did
not create is kept unless you pass `--drop-warehouse`. A warehouse you passed with `--warehouse` or
`--ascend-warehouses` is never dropped. Roles you passed in `--ascend-inherit-roles` are kept; only their
grant to `STRAIKER_ASCEND` goes. Teardown skips a user that is not a service user, because setup
did not create it. Run `SHOW FUTURE GRANTS IN DATABASE <database>` afterwards. No row should name
a Straiker role. Remove the integration in the Straiker console too.

## Related

- Straiker docs: https://docs.straiker.ai
- Snowflake: [key-pair authentication](https://docs.snowflake.com/en/user-guide/key-pair-auth),
  [Cortex Agents](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents),
  [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index).
