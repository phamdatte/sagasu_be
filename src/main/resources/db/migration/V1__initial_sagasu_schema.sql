-- SAGASU: FRESH INSTALL, PostgreSQL 15+, 17 tables.
-- Access JWT without refresh token. No ai_job table or persistent AI queue.
-- Flyway V1 baseline: includes the original schema, logic, and v2 additions.

-- 01_schema.sql
-- Sagasu: 16 entities from Sagasu_overview.jpg + verification_token.
-- Proposed physical design: the supplied ERD contains NO column definitions.
-- PostgreSQL 15+; run ONCE inside an empty database. Does not DROP existing data.
-- Schema creation and transaction boundaries are managed by Flyway.
SET LOCAL search_path = sagasu, public;

CREATE TABLE "user" (
 user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 email varchar(254) NOT NULL CHECK (email = btrim(email) AND position('@' in email)>1),
 password_hash text,
 full_name varchar(150) NOT NULL CHECK (length(btrim(full_name))>0),
 avatar_url text, phone varchar(30),
 role varchar(10) NOT NULL DEFAULT 'USER' CHECK (role IN ('USER','ADMIN')),
 status varchar(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','DELETED')),
 email_verified_at timestamptz,
 oauth_issuer text, oauth_subject text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT user_oauth_pair CHECK ((oauth_issuer IS NULL) = (oauth_subject IS NULL)),
 CONSTRAINT user_auth_method CHECK (password_hash IS NOT NULL OR oauth_subject IS NOT NULL),
 CONSTRAINT user_oauth_unique UNIQUE (oauth_issuer, oauth_subject)
);
CREATE UNIQUE INDEX user_email_ci_uq ON "user" (lower(email));

CREATE TABLE category (
 category_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name varchar(100) NOT NULL UNIQUE, is_active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE post (
 post_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES "user" ON DELETE RESTRICT,
 category_id bigint NOT NULL REFERENCES category ON DELETE RESTRICT,
 post_type varchar(5) NOT NULL CHECK (post_type IN ('LOST','FOUND')),
 title varchar(200) NOT NULL CHECK (length(btrim(title))>0), description text NOT NULL,
 location_text text NOT NULL, latitude numeric(9,6), longitude numeric(9,6),
 event_at timestamptz NOT NULL,
 status varchar(12) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RESERVED','RETURNED','CLOSED','HIDDEN')),
 revision integer NOT NULL DEFAULT 1 CHECK (revision>0),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((latitude IS NULL) = (longitude IS NULL)),
 CHECK (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
);
CREATE INDEX post_discovery_idx ON post (post_type,status,category_id,event_at DESC);
CREATE INDEX post_owner_idx ON post(user_id,created_at DESC);

CREATE TABLE post_image (
 post_image_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 post_id bigint NOT NULL REFERENCES post ON DELETE CASCADE,
 image_url text NOT NULL, sort_order integer NOT NULL DEFAULT 0 CHECK(sort_order>=0),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(post_id,sort_order)
);
-- Portable storage, no extension required. Backend performs similarity search.
-- Exactly 0..1 embedding per image/post as drawn; model dimension is NOT assumed.
CREATE TABLE image_embedding (
 image_embedding_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 post_image_id bigint NOT NULL UNIQUE REFERENCES post_image ON DELETE CASCADE,
 model_name text NOT NULL, model_version text NOT NULL,
 dimensions integer NOT NULL CHECK(dimensions>0), embedding real[] NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(array_ndims(embedding)=1 AND cardinality(embedding)=dimensions),
 CHECK(array_position(embedding,NULL) IS NULL),
 CHECK(NOT (embedding && ARRAY['NaN'::real,'Infinity'::real,'-Infinity'::real]))
);
CREATE TABLE post_text_embedding (
 post_text_embedding_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 post_id bigint NOT NULL UNIQUE REFERENCES post ON DELETE CASCADE,
 model_name text NOT NULL, model_version text NOT NULL,
 source_revision integer NOT NULL CHECK(source_revision>0),
 dimensions integer NOT NULL CHECK(dimensions>0), embedding real[] NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(array_ndims(embedding)=1 AND cardinality(embedding)=dimensions),
 CHECK(array_position(embedding,NULL) IS NULL),
 CHECK(NOT (embedding && ARRAY['NaN'::real,'Infinity'::real,'-Infinity'::real]))
);
CREATE TABLE match_result (
 match_result_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 lost_post_id bigint NOT NULL REFERENCES post ON DELETE CASCADE,
 found_post_id bigint NOT NULL REFERENCES post ON DELETE CASCADE,
 score numeric(7,6) NOT NULL CHECK(score BETWEEN 0 AND 1),
 model_name text NOT NULL, model_version text NOT NULL,
 lost_revision integer NOT NULL CHECK(lost_revision>0),
 found_revision integer NOT NULL CHECK(found_revision>0),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(lost_post_id<>found_post_id), UNIQUE(lost_post_id,found_post_id)
);
CREATE INDEX match_found_idx ON match_result(found_post_id);

CREATE TABLE claim (
 claim_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 post_id bigint NOT NULL REFERENCES post ON DELETE RESTRICT,
 claimant_id bigint NOT NULL REFERENCES "user"(user_id) ON DELETE RESTRICT,
 description text NOT NULL CHECK(length(btrim(description))>0),
 evidence_urls jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(evidence_urls)='array'),
 status varchar(20) NOT NULL DEFAULT 'PENDING'
 CHECK(status IN ('PENDING','NEEDS_INFO','APPROVED','REJECTED','CANCELLED','COMPLETED')),
 finder_confirmed_at timestamptz, claimant_confirmed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(status='COMPLETED' OR (finder_confirmed_at IS NULL OR claimant_confirmed_at IS NULL)),
 CHECK(status IN ('APPROVED','COMPLETED') OR (finder_confirmed_at IS NULL AND claimant_confirmed_at IS NULL)),
 CHECK(status<>'COMPLETED' OR (finder_confirmed_at IS NOT NULL AND claimant_confirmed_at IS NOT NULL))
);
CREATE UNIQUE INDEX claim_active_person_uq ON claim(post_id,claimant_id)
 WHERE status IN ('PENDING','NEEDS_INFO','APPROVED','COMPLETED');
CREATE UNIQUE INDEX claim_winner_uq ON claim(post_id) WHERE status IN ('APPROVED','COMPLETED');
CREATE INDEX claim_claimant_idx ON claim(claimant_id,created_at DESC);
CREATE TABLE claim_record (
 claim_record_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 claim_id bigint NOT NULL REFERENCES claim ON DELETE RESTRICT,
 actor_id bigint REFERENCES "user"(user_id) ON DELETE RESTRICT,
 event_type varchar(30) NOT NULL,
 old_status varchar(20), new_status varchar(20) NOT NULL,
 note text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX claim_record_claim_idx ON claim_record(claim_id,created_at);
CREATE TABLE chat_room (
 chat_room_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 claim_id bigint NOT NULL UNIQUE REFERENCES claim ON DELETE RESTRICT,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE chat_message (
 chat_message_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 chat_room_id bigint NOT NULL REFERENCES chat_room ON DELETE RESTRICT,
 sender_id bigint NOT NULL REFERENCES "user"(user_id) ON DELETE RESTRICT,
 content text, attachment_url text, read_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(NULLIF(btrim(content),'') IS NOT NULL OR NULLIF(btrim(attachment_url),'') IS NOT NULL)
);
CREATE INDEX chat_message_room_idx ON chat_message(chat_room_id,chat_message_id);
CREATE INDEX chat_message_sender_idx ON chat_message(sender_id);
CREATE TABLE report_reason (
 report_reason_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 code varchar(50) NOT NULL UNIQUE, name varchar(150) NOT NULL,
 is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE report (
 report_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 reporter_id bigint NOT NULL REFERENCES "user"(user_id) ON DELETE RESTRICT,
 report_reason_id bigint NOT NULL REFERENCES report_reason ON DELETE RESTRICT,
 post_id bigint REFERENCES post ON DELETE RESTRICT,
 claim_id bigint REFERENCES claim ON DELETE RESTRICT,
 chat_message_id bigint REFERENCES chat_message ON DELETE RESTRICT,
 description text NOT NULL,
 status varchar(15) NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','IN_REVIEW','RESOLVED','DISMISSED')),
 assigned_admin_id bigint REFERENCES "user"(user_id) ON DELETE RESTRICT,
 resolution_note text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(num_nonnulls(post_id,claim_id,chat_message_id)=1),
 CHECK(status NOT IN ('RESOLVED','DISMISSED') OR NULLIF(btrim(resolution_note),'') IS NOT NULL)
);
CREATE INDEX report_queue_idx ON report(status,created_at);
CREATE TABLE report_history (
 report_history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 report_id bigint NOT NULL REFERENCES report ON DELETE RESTRICT,
 actor_id bigint REFERENCES "user"(user_id) ON DELETE RESTRICT,
 -- Optional post context preserves the additional post--report_history link in ERD.
 post_id bigint REFERENCES post ON DELETE RESTRICT,
 action varchar(40) NOT NULL, old_status varchar(15), new_status varchar(15) NOT NULL,
 note text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX report_history_report_idx ON report_history(report_id,created_at);
CREATE TABLE audit_log (
 audit_log_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor_id bigint REFERENCES "user"(user_id) ON DELETE RESTRICT,
 entity_type varchar(50) NOT NULL, entity_id bigint,
 action varchar(50) NOT NULL, details jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_actor_idx ON audit_log(actor_id,created_at DESC);
CREATE TABLE notification (
 notification_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 recipient_id bigint NOT NULL REFERENCES "user"(user_id) ON DELETE CASCADE,
 type varchar(40) NOT NULL, title varchar(200) NOT NULL, body text,
 post_id bigint REFERENCES post ON DELETE CASCADE,
 claim_id bigint REFERENCES claim ON DELETE CASCADE,
 report_id bigint REFERENCES report ON DELETE CASCADE,
 chat_message_id bigint REFERENCES chat_message ON DELETE CASCADE,
 match_result_id bigint REFERENCES match_result ON DELETE CASCADE,
 read_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(num_nonnulls(post_id,claim_id,report_id,chat_message_id,match_result_id)<=1)
);
CREATE INDEX notification_inbox_idx ON notification(recipient_id,created_at DESC);
CREATE INDEX notification_unread_idx ON notification(recipient_id) WHERE read_at IS NULL;
CREATE TABLE verification_token (
 verification_token_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES "user" ON DELETE CASCADE,
 purpose varchar(20) NOT NULL CHECK(purpose IN ('EMAIL_VERIFY','PASSWORD_RESET')),
 -- SHA-256 hex digest of a cryptographically random, high-entropy token; never raw token.
 token_hash varchar(64) NOT NULL UNIQUE CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 target_email varchar(254) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
 consumed_at timestamptz, revoked_at timestamptz,
 CHECK(expires_at>created_at), CHECK(consumed_at IS NULL OR consumed_at>=created_at),
 CHECK(revoked_at IS NULL OR revoked_at>=created_at)
);
CREATE INDEX verification_token_user_idx ON verification_token(user_id,purpose);
CREATE INDEX verification_token_expiry_idx ON verification_token(expires_at);

-- Index every FK whose leading column is not already indexed above.
DO $$ DECLARE r record; BEGIN
 FOR r IN
 SELECT t.relname AS tbl, a.attname AS col
 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
 JOIN pg_namespace n ON n.oid=t.relnamespace
 JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=c.conkey[1]
 WHERE c.contype='f' AND n.nspname='sagasu'
 AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=t.oid AND i.indkey[0]=c.conkey[1])
 LOOP EXECUTE format('CREATE INDEX %I ON sagasu.%I (%I)',r.tbl||'_'||r.col||'_fk_idx',r.tbl,r.col); END LOOP;
END $$;
COMMENT ON TABLE "user" IS 'One local credential and at most one OIDC issuer/subject identity per user. Backend validates OIDC, never trusts email alone for linking.';
COMMENT ON TABLE verification_token IS 'Email/reset token digests only; not OAuth access, refresh, state or ID tokens.';
COMMENT ON TABLE report_history IS 'Business moderation history; actor NULL denotes system. action may record sanctions applied by backend in same transaction.';


-- 02_logic.sql
-- Run after 01_schema.sql. Functions are SECURITY INVOKER: trusted backend only.
SET LOCAL search_path=sagasu,public;
CREATE FUNCTION actor_id() RETURNS bigint LANGUAGE sql STABLE SET search_path=sagasu,pg_temp AS $$
 SELECT NULLIF(current_setting('app.actor_id',true),'')::bigint
$$;
CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at=clock_timestamp(); RETURN NEW; END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['user','category','post','image_embedding','post_text_embedding','match_result','claim','report'] LOOP
 EXECUTE format('CREATE TRIGGER touch_updated_at BEFORE UPDATE ON sagasu.%I FOR EACH ROW EXECUTE FUNCTION sagasu.touch_updated_at()',t);
 END LOOP;
END $$;

CREATE FUNCTION post_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF NEW.user_id<>OLD.user_id OR NEW.post_type<>OLD.post_type THEN
  RAISE EXCEPTION 'Post owner and type are immutable';
 END IF;
 IF ROW(NEW.title,NEW.description,NEW.category_id,NEW.location_text,NEW.event_at,NEW.latitude,NEW.longitude)
 IS DISTINCT FROM ROW(OLD.title,OLD.description,OLD.category_id,OLD.location_text,OLD.event_at,OLD.latitude,OLD.longitude)
 OR NEW.revision=OLD.revision+1 THEN
 NEW.revision=OLD.revision+1;
 ELSE NEW.revision=OLD.revision; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER post_revision BEFORE UPDATE ON post FOR EACH ROW EXECUTE FUNCTION post_revision();
-- Replacing/adding/removing an image changes the source revision, too.
CREATE FUNCTION image_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF TG_OP='UPDATE' AND NEW.post_id<>OLD.post_id THEN RAISE EXCEPTION 'Image cannot change post'; END IF;
 IF TG_OP='UPDATE' AND NEW.image_url IS NOT DISTINCT FROM OLD.image_url THEN RETURN NEW; END IF;
 -- Invalidate old matching results by advancing their source revision.
 IF TG_OP<>'INSERT' THEN DELETE FROM image_embedding WHERE post_image_id=OLD.post_image_id; END IF;
 UPDATE post SET revision=revision+1 WHERE post_id=COALESCE(NEW.post_id,OLD.post_id);
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER image_revision AFTER INSERT OR UPDATE OR DELETE ON post_image FOR EACH ROW EXECUTE FUNCTION image_revision();

CREATE FUNCTION validate_match() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE l post; f post;
BEGIN
 SELECT * INTO l FROM post WHERE post_id=NEW.lost_post_id;
 SELECT * INTO f FROM post WHERE post_id=NEW.found_post_id;
 IF l.post_type IS DISTINCT FROM 'LOST' OR f.post_type IS DISTINCT FROM 'FOUND' THEN
 RAISE EXCEPTION 'Match requires LOST and FOUND posts'; END IF;
 IF NEW.lost_revision<>l.revision OR NEW.found_revision<>f.revision THEN
 RAISE EXCEPTION 'Match uses stale source revisions'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validate_match BEFORE INSERT OR UPDATE ON match_result FOR EACH ROW EXECUTE FUNCTION validate_match();
CREATE VIEW current_match_result AS
 SELECT m.* FROM match_result m JOIN post l ON l.post_id=m.lost_post_id JOIN post f ON f.post_id=m.found_post_id
 WHERE m.lost_revision=l.revision AND m.found_revision=f.revision AND l.status='OPEN' AND f.status='OPEN';

CREATE FUNCTION guard_claim() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE p post;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.post_id<>OLD.post_id OR NEW.claimant_id<>OLD.claimant_id THEN RAISE EXCEPTION 'Claim participants are immutable'; END IF;
  RETURN NEW;
 END IF;
 SELECT * INTO p FROM post WHERE post_id=NEW.post_id FOR NO KEY UPDATE;
 IF NOT FOUND OR p.post_type<>'FOUND' OR p.status<>'OPEN' THEN RAISE EXCEPTION 'Claim requires an OPEN FOUND post'; END IF;
 IF NEW.claimant_id=p.user_id THEN RAISE EXCEPTION 'Cannot claim your own post'; END IF;
 IF NEW.status<>'PENDING' THEN RAISE EXCEPTION 'New claim must be PENDING'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=NEW.claimant_id AND status='ACTIVE' AND email_verified_at IS NOT NULL) THEN
 RAISE EXCEPTION 'Claimant must be active with verified email'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_claim BEFORE INSERT OR UPDATE ON claim FOR EACH ROW EXECUTE FUNCTION guard_claim();
CREATE FUNCTION log_claim() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE owner_id bigint; a bigint;
BEGIN
 SELECT user_id INTO owner_id FROM post WHERE post_id=NEW.post_id;
 a=actor_id();
 IF TG_OP='INSERT' THEN
  INSERT INTO claim_record(claim_id,actor_id,event_type,new_status) VALUES(NEW.claim_id,COALESCE(a,NEW.claimant_id),'CREATED',NEW.status);
  INSERT INTO chat_room(claim_id) VALUES(NEW.claim_id);
  INSERT INTO notification(recipient_id,type,title,claim_id) VALUES(owner_id,'CLAIM_CREATED','New ownership claim',NEW.claim_id);
 ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
  INSERT INTO claim_record(claim_id,actor_id,event_type,old_status,new_status,note)
  VALUES(NEW.claim_id,a,'STATUS_CHANGED',OLD.status,NEW.status,NULLIF(current_setting('app.action_note',true),''));
  INSERT INTO notification(recipient_id,type,title,claim_id)
  SELECT x,'CLAIM_UPDATED','Claim status: '||NEW.status,NEW.claim_id
  FROM unnest(ARRAY[owner_id,NEW.claimant_id]) x WHERE x IS DISTINCT FROM a;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER log_claim AFTER INSERT OR UPDATE ON claim FOR EACH ROW EXECUTE FUNCTION log_claim();
CREATE FUNCTION guard_message() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE claimant bigint; finder bigint; s text;
BEGIN
 IF TG_OP='UPDATE' THEN
 IF ROW(NEW.chat_room_id,NEW.sender_id,NEW.content,NEW.attachment_url) IS DISTINCT FROM ROW(OLD.chat_room_id,OLD.sender_id,OLD.content,OLD.attachment_url) THEN
 RAISE EXCEPTION 'Messages are immutable; only read_at may change'; END IF;
 RETURN NEW; END IF;
 SELECT c.claimant_id,p.user_id,c.status INTO claimant,finder,s FROM chat_room r JOIN claim c USING(claim_id) JOIN post p USING(post_id) WHERE r.chat_room_id=NEW.chat_room_id;
 IF NOT FOUND OR NEW.sender_id NOT IN (claimant,finder) THEN RAISE EXCEPTION 'Sender is not a claim participant'; END IF;
 IF s NOT IN ('PENDING','NEEDS_INFO','APPROVED') THEN RAISE EXCEPTION 'Chat is closed for this claim'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=NEW.sender_id AND status='ACTIVE') THEN RAISE EXCEPTION 'Sender is not active'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_message BEFORE INSERT OR UPDATE ON chat_message FOR EACH ROW EXECUTE FUNCTION guard_message();
CREATE FUNCTION notify_message() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE receiver bigint;
BEGIN
 SELECT CASE WHEN NEW.sender_id=c.claimant_id THEN p.user_id ELSE c.claimant_id END INTO receiver
 FROM chat_room r JOIN claim c USING(claim_id) JOIN post p USING(post_id) WHERE r.chat_room_id=NEW.chat_room_id;
 INSERT INTO notification(recipient_id,type,title,chat_message_id) VALUES(receiver,'CHAT_MESSAGE','New message',NEW.chat_message_id);
 RETURN NEW;
END $$;
CREATE TRIGGER notify_message AFTER INSERT ON chat_message FOR EACH ROW EXECUTE FUNCTION notify_message();
CREATE FUNCTION log_report() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE old_s text; context_post bigint;
BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.status,NEW.assigned_admin_id,NEW.resolution_note) IS NOT DISTINCT FROM ROW(OLD.status,OLD.assigned_admin_id,OLD.resolution_note) THEN RETURN NEW; END IF;
 IF TG_OP='UPDATE' THEN old_s=OLD.status; END IF;
 context_post=NEW.post_id;
 IF NEW.claim_id IS NOT NULL THEN SELECT post_id INTO context_post FROM claim WHERE claim_id=NEW.claim_id; END IF;
 IF NEW.chat_message_id IS NOT NULL THEN
 SELECT c.post_id INTO context_post FROM chat_message m JOIN chat_room r USING(chat_room_id) JOIN claim c USING(claim_id) WHERE m.chat_message_id=NEW.chat_message_id;
 END IF;
 INSERT INTO report_history(report_id,actor_id,post_id,action,old_status,new_status,note)
 VALUES(NEW.report_id,CASE WHEN TG_OP='INSERT' THEN COALESCE(actor_id(),NEW.reporter_id) ELSE actor_id() END,
 context_post,CASE WHEN TG_OP='INSERT' THEN 'CREATED' ELSE 'UPDATED' END,old_s,NEW.status,NEW.resolution_note);
 IF TG_OP='UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
 INSERT INTO notification(recipient_id,type,title,report_id) VALUES(NEW.reporter_id,'REPORT_UPDATED','Report status: '||NEW.status,NEW.report_id);
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER log_report AFTER INSERT OR UPDATE ON report FOR EACH ROW EXECUTE FUNCTION log_report();
-- Deliberately whitelist fields: no password/token/message/evidence copied to audit_log.
CREATE FUNCTION audit_user_access() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF ROW(NEW.role,NEW.status) IS DISTINCT FROM ROW(OLD.role,OLD.status) THEN
 INSERT INTO audit_log(actor_id,entity_type,entity_id,action,details)
 VALUES(actor_id(),'user',NEW.user_id,'ACCESS_CHANGED',jsonb_build_object('old_role',OLD.role,'new_role',NEW.role,'old_status',OLD.status,'new_status',NEW.status)); END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER audit_user_access AFTER UPDATE ON "user" FOR EACH ROW EXECUTE FUNCTION audit_user_access();

-- Service authenticates actor before calling; never expose direct DB access to browsers.
-- All claim mutation functions lock post FIRST, then claim, in the same order.
CREATE FUNCTION change_claim(p_claim bigint,p_actor bigint,p_action text,p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE c claim; p post; pid bigint; next_s text; previous_actor text; previous_note text;
BEGIN
 SELECT post_id INTO pid FROM claim WHERE claim_id=p_claim;
 IF NOT FOUND THEN RAISE EXCEPTION 'Claim not found'; END IF;
 SELECT * INTO p FROM post WHERE post_id=pid FOR NO KEY UPDATE;
 SELECT * INTO c FROM claim WHERE claim_id=p_claim FOR UPDATE;
 IF p_actor IS NULL OR NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=p_actor AND status='ACTIVE') THEN RAISE EXCEPTION 'Active actor required'; END IF;
 IF p.status IN ('RETURNED','CLOSED','HIDDEN') THEN RAISE EXCEPTION 'Post unavailable'; END IF;
 CASE p_action
 WHEN 'APPROVE' THEN
  IF p_actor<>p.user_id OR c.status NOT IN ('PENDING','NEEDS_INFO') OR p.status<>'OPEN' THEN RAISE EXCEPTION 'Cannot approve'; END IF; next_s='APPROVED';
 WHEN 'REQUEST_INFO' THEN
  IF p_actor<>p.user_id OR c.status<>'PENDING' OR NULLIF(btrim(p_note),'') IS NULL THEN RAISE EXCEPTION 'Cannot request info without finder and note'; END IF; next_s='NEEDS_INFO';
 WHEN 'RESUBMIT' THEN
  IF p_actor<>c.claimant_id OR c.status<>'NEEDS_INFO' THEN RAISE EXCEPTION 'Cannot resubmit'; END IF; next_s='PENDING';
 WHEN 'REJECT' THEN
  IF p_actor<>p.user_id OR c.status NOT IN ('PENDING','NEEDS_INFO') THEN RAISE EXCEPTION 'Cannot reject'; END IF; next_s='REJECTED';
 WHEN 'CANCEL' THEN
  IF p_actor<>c.claimant_id OR c.status NOT IN ('PENDING','NEEDS_INFO','APPROVED') OR c.finder_confirmed_at IS NOT NULL OR c.claimant_confirmed_at IS NOT NULL THEN RAISE EXCEPTION 'Cannot cancel'; END IF; next_s='CANCELLED';
 ELSE RAISE EXCEPTION 'Unsupported action'; END CASE;
 previous_actor=current_setting('app.actor_id',true); previous_note=current_setting('app.action_note',true);
 PERFORM set_config('app.actor_id',p_actor::text,true); PERFORM set_config('app.action_note',COALESCE(p_note,''),true);
 UPDATE claim SET status=next_s WHERE claim_id=p_claim;
 IF next_s='APPROVED' THEN UPDATE post SET status='RESERVED' WHERE post_id=pid;
 ELSIF c.status='APPROVED' AND next_s='CANCELLED' THEN UPDATE post SET status='OPEN' WHERE post_id=pid; END IF;
 PERFORM set_config('app.actor_id',COALESCE(previous_actor,''),true); PERFORM set_config('app.action_note',COALESCE(previous_note,''),true);
END $$;
CREATE FUNCTION confirm_handover(p_claim bigint,p_actor bigint) RETURNS void
LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE c claim; p post; pid bigint; previous_actor text; previous_note text;
BEGIN
 SELECT post_id INTO pid FROM claim WHERE claim_id=p_claim;
 IF NOT FOUND THEN RAISE EXCEPTION 'Claim not found'; END IF;
 SELECT * INTO p FROM post WHERE post_id=pid FOR NO KEY UPDATE;
 SELECT * INTO c FROM claim WHERE claim_id=p_claim FOR UPDATE;
 IF p_actor IS NULL OR p_actor NOT IN (c.claimant_id,p.user_id) OR NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=p_actor AND status='ACTIVE') THEN RAISE EXCEPTION 'Active participant required'; END IF;
 IF c.status='COMPLETED' THEN RETURN; END IF;
 IF c.status<>'APPROVED' OR p.status<>'RESERVED' THEN RAISE EXCEPTION 'Claim must be approved and post reserved'; END IF;
 IF (p_actor=p.user_id AND c.finder_confirmed_at IS NOT NULL) OR (p_actor=c.claimant_id AND c.claimant_confirmed_at IS NOT NULL) THEN RETURN; END IF;
 previous_actor=current_setting('app.actor_id',true); previous_note=current_setting('app.action_note',true);
 PERFORM set_config('app.actor_id',p_actor::text,true); PERFORM set_config('app.action_note','',true);
 IF p_actor=p.user_id THEN c.finder_confirmed_at=clock_timestamp(); ELSE c.claimant_confirmed_at=clock_timestamp(); END IF;
 INSERT INTO claim_record(claim_id,actor_id,event_type,old_status,new_status) VALUES(p_claim,p_actor,'HANDOVER_CONFIRMED',c.status,c.status);
 UPDATE claim SET finder_confirmed_at=c.finder_confirmed_at,claimant_confirmed_at=c.claimant_confirmed_at,
 status=CASE WHEN c.finder_confirmed_at IS NOT NULL AND c.claimant_confirmed_at IS NOT NULL THEN 'COMPLETED' ELSE 'APPROVED' END WHERE claim_id=p_claim;
 IF c.finder_confirmed_at IS NOT NULL AND c.claimant_confirmed_at IS NOT NULL THEN
  UPDATE post SET status='RETURNED' WHERE post_id=pid;
  PERFORM set_config('app.action_note','Another claim completed the handover',true);
  UPDATE claim SET status='REJECTED' WHERE post_id=pid AND claim_id<>p_claim AND status IN ('PENDING','NEEDS_INFO');
 END IF;
 PERFORM set_config('app.actor_id',COALESCE(previous_actor,''),true); PERFORM set_config('app.action_note',COALESCE(previous_note,''),true);
END $$;

CREATE FUNCTION consume_verification_token(p_hash text,p_purpose text,p_password_hash text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE uid bigint; u "user"; tok verification_token;
BEGIN
 IF p_purpose IS NULL OR p_purpose NOT IN ('EMAIL_VERIFY','PASSWORD_RESET') THEN RAISE EXCEPTION 'Invalid purpose'; END IF;
 IF p_purpose='PASSWORD_RESET' AND NULLIF(btrim(p_password_hash),'') IS NULL THEN RAISE EXCEPTION 'Backend-generated password hash required'; END IF;
 SELECT user_id INTO uid FROM verification_token WHERE token_hash=p_hash AND purpose=p_purpose;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid or expired token'; END IF;
 -- Lock user first to serialize concurrent consumes of distinct tokens for one user.
 SELECT * INTO u FROM "user" WHERE user_id=uid FOR UPDATE;
 IF u.status<>'ACTIVE' THEN RAISE EXCEPTION 'Invalid or expired token'; END IF;
 UPDATE verification_token SET consumed_at=clock_timestamp()
 WHERE token_hash=p_hash AND purpose=p_purpose AND user_id=uid
 AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>clock_timestamp()
 AND lower(target_email)=lower(u.email)
 RETURNING * INTO tok;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid or expired token'; END IF;
 IF p_purpose='EMAIL_VERIFY' THEN
 UPDATE "user" SET email_verified_at=COALESCE(email_verified_at,clock_timestamp()) WHERE user_id=uid;
 ELSE
 -- Policy: password reset does not add a local password to OAuth-only accounts.
 IF u.password_hash IS NULL THEN RAISE EXCEPTION 'OAuth-only account has no local password'; END IF;
 UPDATE "user" SET password_hash=p_password_hash WHERE user_id=uid;
 END IF;
 UPDATE verification_token SET revoked_at=clock_timestamp() WHERE user_id=uid AND purpose=p_purpose AND consumed_at IS NULL AND revoked_at IS NULL;
 RETURN uid;
END $$;
CREATE PROCEDURE resolve_report(p_report bigint,p_admin bigint,p_status text,p_note text)
LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE r report; previous_actor text;
BEGIN
 IF p_status IS NULL OR p_status NOT IN ('RESOLVED','DISMISSED') OR NULLIF(btrim(p_note),'') IS NULL THEN RAISE EXCEPTION 'Final status and resolution note required'; END IF;
 IF p_admin IS NULL OR NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=p_admin AND role='ADMIN' AND status='ACTIVE') THEN RAISE EXCEPTION 'Active admin required'; END IF;
 SELECT * INTO r FROM report WHERE report_id=p_report FOR UPDATE;
 IF NOT FOUND OR r.status NOT IN ('PENDING','IN_REVIEW') THEN RAISE EXCEPTION 'Report not found or already closed'; END IF;
 previous_actor=current_setting('app.actor_id',true);
 PERFORM set_config('app.actor_id',p_admin::text,true);
 UPDATE report SET status=p_status,assigned_admin_id=p_admin,resolution_note=p_note WHERE report_id=p_report;
 PERFORM set_config('app.actor_id',COALESCE(previous_actor,''),true);
 -- Closing a report does not automatically ban a user or hide a post.
END $$;
CREATE FUNCTION email_changed() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF lower(NEW.email) IS DISTINCT FROM lower(OLD.email) THEN
 NEW.email_verified_at=NULL;
 UPDATE verification_token SET revoked_at=clock_timestamp() WHERE user_id=NEW.user_id AND consumed_at IS NULL AND revoked_at IS NULL;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER email_changed BEFORE UPDATE OF email ON "user" FOR EACH ROW EXECUTE FUNCTION email_changed();
-- PostgreSQL functions are public-executable by default; require explicit backend grants.
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA sagasu FROM PUBLIC;


-- 03_upgrade_v2.sql
-- Sagasu v1 -> current no-queue design. Run ONCE on original 17-table v1 schema.
-- No refresh tokens and no ai_job. Retains 17 tables. No business rows are deleted.
-- Stop application/workers during migration. Metadata unknown for legacy images stays NULL.
SET LOCAL search_path=sagasu,public;
ALTER TABLE "user" ADD COLUMN auth_version integer NOT NULL DEFAULT 0 CHECK(auth_version>=0);
ALTER TABLE post ADD COLUMN moderation_status varchar(10) NOT NULL DEFAULT 'VISIBLE' CHECK(moderation_status IN ('VISIBLE','HIDDEN')),
 ADD COLUMN deleted_at timestamptz;
-- v1 HIDDEN discarded the business status. Recover from claims where possible;
-- otherwise keep CLOSED/HIDDEN for manual review rather than reopen without evidence.
UPDATE post p SET moderation_status='HIDDEN',status=CASE
 WHEN EXISTS(SELECT 1 FROM claim c WHERE c.post_id=p.post_id AND c.status='COMPLETED') THEN 'RETURNED'
 WHEN EXISTS(SELECT 1 FROM claim c WHERE c.post_id=p.post_id AND c.status='APPROVED') THEN 'RESERVED'
 ELSE 'CLOSED' END WHERE status='HIDDEN';
ALTER TABLE post DROP CONSTRAINT post_status_check;
ALTER TABLE post ADD CONSTRAINT post_status_check CHECK(status IN ('OPEN','RESERVED','RETURNED','CLOSED'));
ALTER TABLE post_image ADD COLUMN storage_key text, ADD COLUMN mime_type varchar(100),
 ADD COLUMN size_bytes bigint CHECK(size_bytes>0), ADD COLUMN width integer CHECK(width>0),
 ADD COLUMN height integer CHECK(height>0), ADD COLUMN content_hash varchar(64) CHECK(content_hash ~ '^[0-9a-f]{64}$');
-- image_url retained for v1 compatibility; storage_key becomes canonical for new uploads.
ALTER TABLE post_image ALTER COLUMN image_url DROP NOT NULL;
ALTER TABLE post_image ADD CONSTRAINT image_location_present CHECK(NULLIF(btrim(storage_key),'') IS NOT NULL OR NULLIF(btrim(image_url),'') IS NOT NULL);
ALTER TABLE image_embedding ADD COLUMN source_hash varchar(64) CHECK(source_hash ~ '^[0-9a-f]{64}$');
ALTER TABLE match_result ADD COLUMN matching_version varchar(80) NOT NULL DEFAULT 'v1' CHECK(length(btrim(matching_version))>0);
ALTER TABLE report ADD COLUMN evidence_urls jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(evidence_urls)='array');
ALTER TABLE report_history ADD COLUMN target_user_id bigint REFERENCES "user"(user_id) ON DELETE RESTRICT;
CREATE INDEX report_history_target_user_idx ON report_history(target_user_id);
ALTER TABLE notification ADD COLUMN dedup_key varchar(250) UNIQUE;

CREATE FUNCTION bump_auth_version() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF ROW(NEW.password_hash,NEW.email,NEW.role,NEW.status,NEW.oauth_issuer,NEW.oauth_subject)
 IS DISTINCT FROM ROW(OLD.password_hash,OLD.email,OLD.role,OLD.status,OLD.oauth_issuer,OLD.oauth_subject) THEN
 NEW.auth_version=OLD.auth_version+1;
 ELSIF NEW.auth_version<OLD.auth_version THEN RAISE EXCEPTION 'auth_version cannot decrease'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER bump_auth_version BEFORE UPDATE ON "user" FOR EACH ROW EXECUTE FUNCTION bump_auth_version();
CREATE FUNCTION logout_all_sessions(p_user bigint,p_verified_version integer) RETURNS integer
LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE v integer;
BEGIN
 UPDATE "user" SET auth_version=auth_version+1 WHERE user_id=p_user AND auth_version=p_verified_version AND status='ACTIVE'
 RETURNING auth_version INTO v;
 IF NOT FOUND THEN RAISE EXCEPTION 'Session is no longer current'; END IF;
 INSERT INTO audit_log(actor_id,entity_type,entity_id,action) VALUES(p_user,'user',p_user,'LOGOUT_ALL');
 RETURN v;
END $$;

CREATE OR REPLACE FUNCTION post_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF NEW.user_id<>OLD.user_id OR NEW.post_type<>OLD.post_type THEN RAISE EXCEPTION 'Post owner and type are immutable'; END IF;
 IF ((NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL) OR (NEW.status='CLOSED' AND OLD.status<>'CLOSED'))
 AND EXISTS(SELECT 1 FROM claim WHERE post_id=OLD.post_id AND status IN ('PENDING','NEEDS_INFO','APPROVED')) THEN
 RAISE EXCEPTION 'Resolve active claims before closing or deleting this post'; END IF;
 IF ROW(NEW.title,NEW.description,NEW.category_id,NEW.location_text,NEW.event_at,NEW.latitude,NEW.longitude,NEW.status,NEW.moderation_status,NEW.deleted_at)
 IS DISTINCT FROM ROW(OLD.title,OLD.description,OLD.category_id,OLD.location_text,OLD.event_at,OLD.latitude,OLD.longitude,OLD.status,OLD.moderation_status,OLD.deleted_at)
 OR NEW.revision=OLD.revision+1 THEN NEW.revision=OLD.revision+1;
 ELSE NEW.revision=OLD.revision; END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION guard_image_metadata() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF TG_OP='UPDATE' AND NEW.post_id<>OLD.post_id THEN RAISE EXCEPTION 'Image cannot change post'; END IF;
 -- Legacy rows may lack metadata: allow read/sort changes, require backfill on file changes.
 IF TG_OP='INSERT' OR ROW(NEW.storage_key,NEW.image_url,NEW.content_hash) IS DISTINCT FROM ROW(OLD.storage_key,OLD.image_url,OLD.content_hash) THEN
 IF NULLIF(btrim(NEW.storage_key),'') IS NULL OR NEW.content_hash IS NULL
 OR NEW.mime_type IS NULL OR NEW.mime_type NOT IN ('image/jpeg','image/png','image/webp')
 OR NEW.size_bytes IS NULL OR NEW.width IS NULL OR NEW.height IS NULL THEN
 RAISE EXCEPTION 'Verified storage key/hash/MIME/size/dimensions required for new or changed image'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_image_metadata BEFORE INSERT OR UPDATE ON post_image FOR EACH ROW EXECUTE FUNCTION guard_image_metadata();
CREATE OR REPLACE FUNCTION image_revision() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
BEGIN
 IF TG_OP='UPDATE' AND ROW(NEW.storage_key,NEW.image_url,NEW.content_hash) IS NOT DISTINCT FROM ROW(OLD.storage_key,OLD.image_url,OLD.content_hash) THEN RETURN NEW; END IF;
 IF TG_OP<>'INSERT' THEN DELETE FROM image_embedding WHERE post_image_id=OLD.post_image_id; END IF;
 UPDATE post SET revision=revision+1 WHERE post_id=COALESCE(NEW.post_id,OLD.post_id);
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE FUNCTION guard_image_embedding() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE h text;
BEGIN
 SELECT content_hash INTO h FROM post_image WHERE post_image_id=NEW.post_image_id FOR SHARE;
 IF h IS NULL OR NEW.source_hash IS DISTINCT FROM h THEN RAISE EXCEPTION 'Embedding requires current source image hash'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_image_embedding BEFORE INSERT OR UPDATE ON image_embedding FOR EACH ROW EXECUTE FUNCTION guard_image_embedding();
CREATE FUNCTION guard_text_embedding() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE r integer;
BEGIN
 SELECT revision INTO r FROM post WHERE post_id=NEW.post_id FOR SHARE;
 IF r IS NULL OR NEW.source_revision<>r THEN RAISE EXCEPTION 'Text embedding revision is stale'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_text_embedding BEFORE INSERT OR UPDATE ON post_text_embedding FOR EACH ROW EXECUTE FUNCTION guard_text_embedding();
CREATE VIEW current_image_embedding AS SELECT e.* FROM image_embedding e JOIN post_image i USING(post_image_id)
 WHERE e.source_hash=i.content_hash AND e.source_hash IS NOT NULL;
CREATE VIEW current_post_text_embedding AS SELECT e.* FROM post_text_embedding e JOIN post p USING(post_id) WHERE e.source_revision=p.revision;

-- Search path #1: keyword search/filter. Accent-sensitive simple full-text search, no AI.
ALTER TABLE post ADD COLUMN search_document tsvector GENERATED ALWAYS AS
 (setweight(to_tsvector('simple'::regconfig,coalesce(title,'')),'A') ||
  setweight(to_tsvector('simple'::regconfig,coalesce(description,'')),'B') ||
  setweight(to_tsvector('simple'::regconfig,coalesce(location_text,'')),'C')) STORED;
CREATE INDEX post_search_gin_idx ON post USING gin(search_document);
CREATE INDEX post_public_filter_idx ON post(post_type,category_id,event_at DESC,post_id DESC)
 WHERE status='OPEN' AND moderation_status='VISIBLE' AND deleted_at IS NULL;
CREATE VIEW searchable_post AS SELECT p.* FROM post p JOIN "user" u ON u.user_id=p.user_id
 WHERE p.status='OPEN' AND p.moderation_status='VISIBLE' AND p.deleted_at IS NULL AND u.status='ACTIVE';
CREATE FUNCTION search_posts(p_keyword text DEFAULT NULL,p_type text DEFAULT NULL,p_category bigint DEFAULT NULL,
 p_location text DEFAULT NULL,p_from timestamptz DEFAULT NULL,p_until timestamptz DEFAULT NULL,
 p_limit integer DEFAULT 20,p_offset integer DEFAULT 0)
RETURNS SETOF searchable_post LANGUAGE plpgsql STABLE SET search_path=sagasu,pg_temp AS $$
DECLARE q tsquery;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'Invalid pagination'; END IF;
 IF p_type IS NOT NULL AND p_type NOT IN ('LOST','FOUND') THEN RAISE EXCEPTION 'Invalid post type'; END IF;
 IF p_from IS NOT NULL AND p_until IS NOT NULL AND p_from>=p_until THEN RAISE EXCEPTION 'Invalid time range'; END IF;
 q=websearch_to_tsquery('simple',coalesce(p_keyword,''));
 RETURN QUERY SELECT p.* FROM searchable_post p
 WHERE (NULLIF(btrim(p_keyword),'') IS NULL OR p.search_document@@q)
 AND (p_type IS NULL OR p.post_type=p_type) AND (p_category IS NULL OR p.category_id=p_category)
 AND (NULLIF(btrim(p_location),'') IS NULL OR strpos(lower(p.location_text),lower(btrim(p_location)))>0)
 AND (p_from IS NULL OR p.event_at>=p_from) AND (p_until IS NULL OR p.event_at<p_until)
 ORDER BY ts_rank(p.search_document,q) DESC,p.created_at DESC,p.post_id DESC LIMIT p_limit OFFSET p_offset;
END $$;
CREATE OR REPLACE VIEW current_match_result AS SELECT m.* FROM match_result m
 JOIN searchable_post l ON l.post_id=m.lost_post_id JOIN searchable_post f ON f.post_id=m.found_post_id
 WHERE m.lost_revision=l.revision AND m.found_revision=f.revision;
CREATE OR REPLACE FUNCTION validate_match() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE l post; f post;
BEGIN
 -- Stable lock order for pairs; prevents validating against a concurrently edited post.
 PERFORM post_id FROM post WHERE post_id IN(NEW.lost_post_id,NEW.found_post_id) ORDER BY post_id FOR SHARE;
 SELECT * INTO l FROM post WHERE post_id=NEW.lost_post_id;
 SELECT * INTO f FROM post WHERE post_id=NEW.found_post_id;
 IF l.post_type IS DISTINCT FROM 'LOST' OR f.post_type IS DISTINCT FROM 'FOUND' THEN RAISE EXCEPTION 'Match requires LOST and FOUND'; END IF;
 IF NEW.lost_revision<>l.revision OR NEW.found_revision<>f.revision THEN RAISE EXCEPTION 'Stale source revisions'; END IF;
 IF l.status<>'OPEN' OR f.status<>'OPEN' OR l.moderation_status<>'VISIBLE' OR f.moderation_status<>'VISIBLE'
 OR l.deleted_at IS NOT NULL OR f.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Posts not eligible for matching'; END IF;
 RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION consume_verification_token(p_hash text,p_purpose text,p_password_hash text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE uid bigint; u "user"; tok verification_token;
BEGIN
 IF p_purpose IS NULL OR p_purpose NOT IN ('EMAIL_VERIFY','PASSWORD_RESET') THEN RAISE EXCEPTION 'Invalid purpose'; END IF;
 IF p_purpose='PASSWORD_RESET' AND NULLIF(btrim(p_password_hash),'') IS NULL THEN RAISE EXCEPTION 'Backend-generated password hash required'; END IF;
 SELECT user_id INTO uid FROM verification_token WHERE token_hash=p_hash AND purpose=p_purpose;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid or expired token'; END IF;
 -- Lock user first to serialize concurrent consumes of distinct tokens for one user.
 SELECT * INTO u FROM "user" WHERE user_id=uid FOR UPDATE;
 IF u.status<>'ACTIVE' THEN RAISE EXCEPTION 'Invalid or expired token'; END IF;
 UPDATE verification_token SET consumed_at=clock_timestamp()
 WHERE token_hash=p_hash AND purpose=p_purpose AND user_id=uid
 AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>clock_timestamp()
 AND lower(target_email)=lower(u.email)
 RETURNING * INTO tok;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid or expired token'; END IF;
 IF p_purpose='EMAIL_VERIFY' THEN
 UPDATE "user" SET email_verified_at=COALESCE(email_verified_at,clock_timestamp()) WHERE user_id=uid;
 ELSE
 -- Policy: password reset does not add a local password to OAuth-only accounts.
 IF u.password_hash IS NULL THEN RAISE EXCEPTION 'OAuth-only account has no local password'; END IF;
 UPDATE "user" SET password_hash=p_password_hash,auth_version=auth_version+1 WHERE user_id=uid;
 END IF;
 UPDATE verification_token SET revoked_at=clock_timestamp() WHERE user_id=uid AND purpose=p_purpose AND consumed_at IS NULL AND revoked_at IS NULL;
 RETURN uid;
END $$;

-- Hidden posts block new claims/approvals but preserve existing approved handovers.
CREATE OR REPLACE FUNCTION guard_claim() RETURNS trigger LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE p post;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.post_id<>OLD.post_id OR NEW.claimant_id<>OLD.claimant_id THEN RAISE EXCEPTION 'Claim participants are immutable'; END IF;
  RETURN NEW;
 END IF;
 SELECT * INTO p FROM post WHERE post_id=NEW.post_id FOR NO KEY UPDATE;
 IF NOT FOUND OR p.post_type<>'FOUND' OR p.status<>'OPEN' OR p.moderation_status<>'VISIBLE' OR p.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Claim requires an OPEN FOUND post'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=p.user_id AND status='ACTIVE') THEN RAISE EXCEPTION 'Post owner is not active'; END IF;
 IF NEW.claimant_id=p.user_id THEN RAISE EXCEPTION 'Cannot claim your own post'; END IF;
 IF NEW.status<>'PENDING' THEN RAISE EXCEPTION 'New claim must be PENDING'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=NEW.claimant_id AND status='ACTIVE' AND email_verified_at IS NOT NULL) THEN
 RAISE EXCEPTION 'Claimant must be active with verified email'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION change_claim(p_claim bigint,p_actor bigint,p_action text,p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE c claim; p post; pid bigint; next_s text; previous_actor text; previous_note text;
BEGIN
 SELECT post_id INTO pid FROM claim WHERE claim_id=p_claim;
 IF NOT FOUND THEN RAISE EXCEPTION 'Claim not found'; END IF;
 SELECT * INTO p FROM post WHERE post_id=pid FOR NO KEY UPDATE;
 SELECT * INTO c FROM claim WHERE claim_id=p_claim FOR UPDATE;
 IF p_actor IS NULL OR NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=p_actor AND status='ACTIVE') THEN RAISE EXCEPTION 'Active actor required'; END IF;
 IF p.status IN ('RETURNED','CLOSED') OR p.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Post unavailable'; END IF;
 CASE p_action
 WHEN 'APPROVE' THEN
  IF p.moderation_status<>'VISIBLE' THEN RAISE EXCEPTION 'Cannot approve a new claim on a hidden post'; END IF;
  IF p_actor<>p.user_id OR c.status NOT IN ('PENDING','NEEDS_INFO') OR p.status<>'OPEN' THEN RAISE EXCEPTION 'Cannot approve'; END IF; next_s='APPROVED';
 WHEN 'REQUEST_INFO' THEN
  IF p_actor<>p.user_id OR c.status<>'PENDING' OR NULLIF(btrim(p_note),'') IS NULL THEN RAISE EXCEPTION 'Cannot request info without finder and note'; END IF; next_s='NEEDS_INFO';
 WHEN 'RESUBMIT' THEN
  IF p_actor<>c.claimant_id OR c.status<>'NEEDS_INFO' THEN RAISE EXCEPTION 'Cannot resubmit'; END IF; next_s='PENDING';
 WHEN 'REJECT' THEN
  IF p_actor<>p.user_id OR c.status NOT IN ('PENDING','NEEDS_INFO') THEN RAISE EXCEPTION 'Cannot reject'; END IF; next_s='REJECTED';
 WHEN 'CANCEL' THEN
  IF p_actor<>c.claimant_id OR c.status NOT IN ('PENDING','NEEDS_INFO','APPROVED') OR c.finder_confirmed_at IS NOT NULL OR c.claimant_confirmed_at IS NOT NULL THEN RAISE EXCEPTION 'Cannot cancel'; END IF; next_s='CANCELLED';
 ELSE RAISE EXCEPTION 'Unsupported action'; END CASE;
 previous_actor=current_setting('app.actor_id',true); previous_note=current_setting('app.action_note',true);
 PERFORM set_config('app.actor_id',p_actor::text,true); PERFORM set_config('app.action_note',COALESCE(p_note,''),true);
 UPDATE claim SET status=next_s WHERE claim_id=p_claim;
 IF next_s='APPROVED' THEN UPDATE post SET status='RESERVED' WHERE post_id=pid;
 ELSIF c.status='APPROVED' AND next_s='CANCELLED' THEN UPDATE post SET status='OPEN' WHERE post_id=pid; END IF;
 PERFORM set_config('app.actor_id',COALESCE(previous_actor,''),true); PERFORM set_config('app.action_note',COALESCE(previous_note,''),true);
END $$;
CREATE OR REPLACE FUNCTION confirm_handover(p_claim bigint,p_actor bigint) RETURNS void
LANGUAGE plpgsql SET search_path=sagasu,pg_temp AS $$
DECLARE c claim; p post; pid bigint; previous_actor text; previous_note text;
BEGIN
 SELECT post_id INTO pid FROM claim WHERE claim_id=p_claim;
 IF NOT FOUND THEN RAISE EXCEPTION 'Claim not found'; END IF;
 SELECT * INTO p FROM post WHERE post_id=pid FOR NO KEY UPDATE;
 SELECT * INTO c FROM claim WHERE claim_id=p_claim FOR UPDATE;
 IF p_actor IS NULL OR p_actor NOT IN (c.claimant_id,p.user_id) OR NOT EXISTS(SELECT 1 FROM "user" WHERE user_id=p_actor AND status='ACTIVE') THEN RAISE EXCEPTION 'Active participant required'; END IF;
 IF c.status='COMPLETED' THEN RETURN; END IF;
 IF c.status<>'APPROVED' OR p.status<>'RESERVED' OR p.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Claim must be approved and post reserved'; END IF;
 IF (p_actor=p.user_id AND c.finder_confirmed_at IS NOT NULL) OR (p_actor=c.claimant_id AND c.claimant_confirmed_at IS NOT NULL) THEN RETURN; END IF;
 previous_actor=current_setting('app.actor_id',true); previous_note=current_setting('app.action_note',true);
 PERFORM set_config('app.actor_id',p_actor::text,true); PERFORM set_config('app.action_note','',true);
 IF p_actor=p.user_id THEN c.finder_confirmed_at=clock_timestamp(); ELSE c.claimant_confirmed_at=clock_timestamp(); END IF;
 INSERT INTO claim_record(claim_id,actor_id,event_type,old_status,new_status) VALUES(p_claim,p_actor,'HANDOVER_CONFIRMED',c.status,c.status);
 UPDATE claim SET finder_confirmed_at=c.finder_confirmed_at,claimant_confirmed_at=c.claimant_confirmed_at,
 status=CASE WHEN c.finder_confirmed_at IS NOT NULL AND c.claimant_confirmed_at IS NOT NULL THEN 'COMPLETED' ELSE 'APPROVED' END WHERE claim_id=p_claim;
 IF c.finder_confirmed_at IS NOT NULL AND c.claimant_confirmed_at IS NOT NULL THEN
  UPDATE post SET status='RETURNED' WHERE post_id=pid;
  PERFORM set_config('app.action_note','Another claim completed the handover',true);
  UPDATE claim SET status='REJECTED' WHERE post_id=pid AND claim_id<>p_claim AND status IN ('PENDING','NEEDS_INFO');
 END IF;
 PERFORM set_config('app.actor_id',COALESCE(previous_actor,''),true); PERFORM set_config('app.action_note',COALESCE(previous_note,''),true);
END $$;

COMMENT ON COLUMN "user".auth_version IS 'Compare with verified JWT claim on every request; password/email/role/status/OIDC changes increment this value. Logout affects all devices.';
COMMENT ON COLUMN post_image.storage_key IS 'Canonical immutable object key; signed download URLs are generated by backend and not stored here.';
COMMENT ON COLUMN report.evidence_urls IS 'JSON array of authorized object references; validate each element and access in backend.';
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA sagasu FROM PUBLIC;
