-- TDAI Memory PostgreSQL Schema Dump
-- Database: tdai_memory
-- Generated: 2026-08-27T09:07:47.002Z
-- PG: PostgreSQL 16.13 + pgvector 0.8.2 + pg_trgm 1.6

-- Extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Table: embedding_meta
CREATE TABLE IF NOT EXISTS embedding_meta (
  key text NOT NULL,
  value text NOT NULL
);


-- Table: entity_agents
CREATE TABLE IF NOT EXISTS entity_agents (
  agent_id text NOT NULL,
  team_id text NOT NULL,
  name text NOT NULL,
  description text DEFAULT ''::text,
  prompt text DEFAULT ''::text,
  owner_user_id text DEFAULT ''::text,
  visibility text NOT NULL DEFAULT 'team'::text,
  status text NOT NULL DEFAULT 'active'::text,
  created_at text NOT NULL,
  updated_at text NOT NULL
);


-- Table: entity_knowledge
CREATE TABLE IF NOT EXISTS entity_knowledge (
  knowledge_id text NOT NULL,
  type text NOT NULL,
  service_url text NOT NULL,
  name text NOT NULL,
  summary text,
  team_id text NOT NULL,
  agent_id text NOT NULL DEFAULT ''::text,
  user_id text,
  repo_url text,
  branch text,
  created_at text NOT NULL,
  updated_at text NOT NULL
);


-- Table: entity_tasks
CREATE TABLE IF NOT EXISTS entity_tasks (
  task_id text NOT NULL,
  team_id text NOT NULL,
  creator_user_id text NOT NULL,
  title text DEFAULT ''::text,
  description text DEFAULT ''::text,
  source_type text NOT NULL DEFAULT 'manual'::text,
  source_url text DEFAULT ''::text,
  status text NOT NULL DEFAULT 'pending'::text,
  auto_assign_floating_assets integer NOT NULL DEFAULT 0,
  risk_level text NOT NULL DEFAULT 'low'::text,
  agent_ids_json text NOT NULL DEFAULT '[]'::text,
  user_ids_json text NOT NULL DEFAULT '[]'::text,
  created_at text NOT NULL,
  updated_at text NOT NULL
);


-- Table: entity_teams
CREATE TABLE IF NOT EXISTS entity_teams (
  team_id text NOT NULL,
  name text NOT NULL,
  description text DEFAULT ''::text,
  owner_user_id text NOT NULL,
  user_ids_json text NOT NULL DEFAULT '[]'::text,
  agent_ids_json text NOT NULL DEFAULT '[]'::text,
  status text NOT NULL DEFAULT 'active'::text,
  created_at text NOT NULL,
  updated_at text NOT NULL
);


-- Table: entity_users
CREATE TABLE IF NOT EXISTS entity_users (
  user_id text NOT NULL,
  name text NOT NULL,
  job_description text DEFAULT ''::text,
  team_ids_json text NOT NULL DEFAULT '[]'::text,
  task_ids_json text NOT NULL DEFAULT '[]'::text,
  owned_agent_ids_json text NOT NULL DEFAULT '[]'::text,
  status text NOT NULL DEFAULT 'active'::text,
  created_at text NOT NULL,
  updated_at text NOT NULL
);


-- Table: l0_conversations
CREATE TABLE IF NOT EXISTS l0_conversations (
  record_id text NOT NULL,
  session_key text NOT NULL,
  session_id text NOT NULL DEFAULT 'default'::text,
  team_id text NOT NULL DEFAULT 'default'::text,
  task_id text NOT NULL DEFAULT ''::text,
  user_id text NOT NULL DEFAULT 'default'::text,
  agent_id text NOT NULL DEFAULT 'default'::text,
  role text NOT NULL DEFAULT ''::text,
  message_text text NOT NULL,
  message_segmented text NOT NULL DEFAULT ''::text,
  recorded_at text NOT NULL DEFAULT ''::text,
  timestamp bigint NOT NULL DEFAULT 0,
  embedding vector(1024),
  message_tsv tsvector
);

CREATE INDEX idx_l0_session ON public.l0_conversations USING btree (session_key);
CREATE INDEX idx_l0_session_id ON public.l0_conversations USING btree (session_id);
CREATE INDEX idx_l0_user_agent_session ON public.l0_conversations USING btree (user_id, agent_id, session_id);
CREATE INDEX idx_l0_timestamp ON public.l0_conversations USING btree ("timestamp");
CREATE INDEX idx_l0_message_tsv ON public.l0_conversations USING gin (message_tsv);
CREATE INDEX idx_l0_vec ON public.l0_conversations USING ivfflat (embedding vector_cosine_ops) WITH (lists='100');

-- Table: l1_records
CREATE TABLE IF NOT EXISTS l1_records (
  record_id text NOT NULL,
  content text NOT NULL DEFAULT ''::text,
  content_segmented text NOT NULL DEFAULT ''::text,
  type text NOT NULL DEFAULT ''::text,
  priority integer NOT NULL DEFAULT 50,
  scene_name text NOT NULL DEFAULT ''::text,
  session_key text NOT NULL DEFAULT ''::text,
  session_id text NOT NULL DEFAULT 'default'::text,
  team_id text NOT NULL DEFAULT 'default'::text,
  task_id text NOT NULL DEFAULT ''::text,
  user_id text NOT NULL DEFAULT 'default'::text,
  agent_id text NOT NULL DEFAULT 'default'::text,
  version integer NOT NULL DEFAULT 0,
  timestamp_str text NOT NULL DEFAULT ''::text,
  timestamp_start text NOT NULL DEFAULT ''::text,
  timestamp_end text NOT NULL DEFAULT ''::text,
  created_time text NOT NULL DEFAULT ''::text,
  updated_time text NOT NULL DEFAULT ''::text,
  metadata_json text NOT NULL DEFAULT '{}'::text,
  embedding vector(1024),
  content_tsv tsvector
);

CREATE INDEX idx_l1_type ON public.l1_records USING btree (type);
CREATE INDEX idx_l1_session_id ON public.l1_records USING btree (session_id);
CREATE INDEX idx_l1_session_key ON public.l1_records USING btree (session_key);
CREATE INDEX idx_l1_session_updated ON public.l1_records USING btree (session_id, updated_time);
CREATE INDEX idx_l1_team_agent_updated ON public.l1_records USING btree (team_id, agent_id, updated_time);
CREATE INDEX idx_l1_user_agent_session ON public.l1_records USING btree (user_id, agent_id, session_id);
CREATE INDEX idx_l1_content_tsv ON public.l1_records USING gin (content_tsv);
CREATE INDEX idx_l1_vec ON public.l1_records USING ivfflat (embedding vector_cosine_ops) WITH (lists='100');

-- Table: memory_audit
CREATE TABLE IF NOT EXISTS memory_audit (
  audit_id text NOT NULL,
  record_id text NOT NULL,
  layer text NOT NULL,
  action text NOT NULL,
  team_id text,
  agent_id text,
  user_id text,
  task_id text,
  version integer NOT NULL,
  updated_at_ms bigint NOT NULL,
  request_id text
);

CREATE INDEX idx_memory_audit_record ON public.memory_audit USING btree (record_id, updated_at_ms);
CREATE INDEX idx_memory_audit_time ON public.memory_audit USING btree (updated_at_ms);

-- Primary Keys
CREATE UNIQUE INDEX embedding_meta_pkey ON public.embedding_meta USING btree (key);
CREATE UNIQUE INDEX entity_agents_pkey ON public.entity_agents USING btree (agent_id);
CREATE UNIQUE INDEX entity_knowledge_pkey ON public.entity_knowledge USING btree (knowledge_id);
CREATE UNIQUE INDEX entity_tasks_pkey ON public.entity_tasks USING btree (task_id);
CREATE UNIQUE INDEX entity_teams_pkey ON public.entity_teams USING btree (team_id);
CREATE UNIQUE INDEX entity_users_pkey ON public.entity_users USING btree (user_id);
CREATE UNIQUE INDEX l0_conversations_pkey ON public.l0_conversations USING btree (record_id);
CREATE UNIQUE INDEX l1_records_pkey ON public.l1_records USING btree (record_id);
CREATE UNIQUE INDEX memory_audit_pkey ON public.memory_audit USING btree (audit_id);

