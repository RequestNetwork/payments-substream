-- Local docker-compose only: runs once on a fresh postgres volume (/docker-entrypoint-initdb.d).
-- `substreams sink postgres setup` does not create the Postgres schema named by the DSN's
-- schemaName= and fails with "no schema has been selected to create in" without it. In GCP the
-- schemas are created by request-infrastructure scripts/setup-payments-db.sql instead.
-- One schema per chain (docs/contract.md "Physical layout"), so any CHAINS value works locally.
CREATE SCHEMA IF NOT EXISTS tron;
CREATE SCHEMA IF NOT EXISTS sepolia;
CREATE SCHEMA IF NOT EXISTS base;
CREATE SCHEMA IF NOT EXISTS mainnet;
CREATE SCHEMA IF NOT EXISTS matic;
CREATE SCHEMA IF NOT EXISTS bsc;
CREATE SCHEMA IF NOT EXISTS arbitrum_one;
CREATE SCHEMA IF NOT EXISTS optimism;
