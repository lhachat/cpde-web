--
-- PostgreSQL database dump
--

\restrict xFF1uuNeyHIgYQG0VqNYzGxHumKGxFUetdHNLExYjlLLtyfBb55LDM5AlST6cBK

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: fte_amt; Type: DOMAIN; Schema: public; Owner: cpde
--

CREATE DOMAIN public.fte_amt AS numeric(7,3)
	CONSTRAINT fte_amt_check CHECK ((VALUE >= (0)::numeric));


ALTER DOMAIN public.fte_amt OWNER TO cpde;

--
-- Name: money_amt; Type: DOMAIN; Schema: public; Owner: cpde
--

CREATE DOMAIN public.money_amt AS numeric(18,2);


ALTER DOMAIN public.money_amt OWNER TO cpde;

--
-- Name: pct_prob; Type: DOMAIN; Schema: public; Owner: cpde
--

CREATE DOMAIN public.pct_prob AS numeric(9,6)
	CONSTRAINT pct_prob_check CHECK (((VALUE >= (0)::numeric) AND (VALUE <= (1)::numeric)));


ALTER DOMAIN public.pct_prob OWNER TO cpde;

--
-- Name: rate_frac; Type: DOMAIN; Schema: public; Owner: cpde
--

CREATE DOMAIN public.rate_frac AS numeric(9,6);


ALTER DOMAIN public.rate_frac OWNER TO cpde;

--
-- Name: current_tenant(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.current_tenant() RETURNS uuid
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v TEXT;
BEGIN
    v := current_setting('app.client_id', true);
    IF v IS NULL OR v = '' THEN
        -- Fail CLOSED. No context means no rows, never all rows.
        RETURN '00000000-0000-0000-0000-000000000000'::uuid;
    END IF;
    RETURN v::uuid;
EXCEPTION WHEN others THEN
    RETURN '00000000-0000-0000-0000-000000000000'::uuid;
END; $$;


ALTER FUNCTION public.current_tenant() OWNER TO cpde;

--
-- Name: FUNCTION current_tenant(); Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON FUNCTION public.current_tenant() IS 'Returns the all-zero UUID when no tenant context is set, so a query without context matches nothing. Fails closed by construction.';


--
-- Name: fn_inherit_client_from_assessment(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_inherit_client_from_assessment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM pwin_assessment WHERE id = NEW.pwin_assessment_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from assessment %', NEW.pwin_assessment_id;
    END IF;
    RETURN NEW;
END; $$;


ALTER FUNCTION public.fn_inherit_client_from_assessment() OWNER TO cpde;

--
-- Name: fn_inherit_client_from_org(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_inherit_client_from_org() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM org_node WHERE id = NEW.org_node_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from org_node %', NEW.org_node_id;
    END IF;
    RETURN NEW;
END; $$;


ALTER FUNCTION public.fn_inherit_client_from_org() OWNER TO cpde;

--
-- Name: fn_inherit_client_from_pursuit(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_inherit_client_from_pursuit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM pursuit WHERE id = NEW.pursuit_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from pursuit %', NEW.pursuit_id;
    END IF;
    RETURN NEW;
END; $$;


ALTER FUNCTION public.fn_inherit_client_from_pursuit() OWNER TO cpde;

--
-- Name: fn_inherit_client_from_user(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_inherit_client_from_user() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT client_id INTO NEW.client_id FROM app_user WHERE id = NEW.user_id;
    IF NEW.client_id IS NULL THEN
        RAISE EXCEPTION 'cannot resolve client_id from app_user %', NEW.user_id;
    END IF;
    RETURN NEW;
END; $$;


ALTER FUNCTION public.fn_inherit_client_from_user() OWNER TO cpde;

--
-- Name: fn_market_code_immutable(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_market_code_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'market.code is immutable (attempted % -> %)', OLD.code, NEW.code;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_market_code_immutable() OWNER TO cpde;

--
-- Name: fn_org_node_validate(); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_org_node_validate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    parent_type   TEXT;
    parent_client UUID;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT node_type, client_id INTO parent_type, parent_client
      FROM org_node WHERE id = NEW.parent_id;

    IF parent_client <> NEW.client_id THEN
        RAISE EXCEPTION 'org_node % parent belongs to a different client', NEW.code;
    END IF;

    IF NOT ( (NEW.node_type = 'business_unit' AND parent_type = 'business')
          OR (NEW.node_type = 'division'      AND parent_type = 'business_unit') ) THEN
        RAISE EXCEPTION 'invalid org nesting: % under %', NEW.node_type, parent_type;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_org_node_validate() OWNER TO cpde;

--
-- Name: fn_user_visible_org_nodes(uuid); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.fn_user_visible_org_nodes(p_user_id uuid) RETURNS TABLE(org_node_id uuid)
    LANGUAGE sql STABLE
    AS $$
    WITH RECURSIVE assigned AS (
        SELECT o.id, o.parent_id
          FROM org_node o
          JOIN user_scope_assignment usa ON usa.org_node_id = o.id
         WHERE usa.user_id = p_user_id
           AND o.is_active
        UNION ALL
        SELECT c.id, c.parent_id
          FROM org_node c
          JOIN assigned a ON c.parent_id = a.id
         WHERE c.is_active
    )
    SELECT DISTINCT id FROM assigned;
$$;


ALTER FUNCTION public.fn_user_visible_org_nodes(p_user_id uuid) OWNER TO cpde;

--
-- Name: set_tenant(uuid); Type: FUNCTION; Schema: public; Owner: cpde
--

CREATE FUNCTION public.set_tenant(p_client_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- SET LOCAL: reverts at COMMIT/ROLLBACK, so a pooled connection cannot
    -- carry this tenant into the next request.
    PERFORM set_config('app.client_id', p_client_id::text, true);
END; $$;


ALTER FUNCTION public.set_tenant(p_client_id uuid) OWNER TO cpde;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_user; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.app_user (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id uuid NOT NULL,
    email text NOT NULL,
    display_name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.app_user FORCE ROW LEVEL SECURITY;


ALTER TABLE public.app_user OWNER TO cpde;

--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    client_id uuid,
    user_id uuid,
    action text NOT NULL,
    table_name text,
    record_id uuid,
    changed_fields jsonb,
    ip_address inet,
    user_agent text
);

ALTER TABLE ONLY public.audit_log FORCE ROW LEVEL SECURITY;


ALTER TABLE public.audit_log OWNER TO cpde;

--
-- Name: TABLE audit_log; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON TABLE public.audit_log IS 'Required for NIST 800-171 / CMMC regardless of hosting tier. Build now; retrofitting audit trails after the fact is materially harder.';


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.audit_log_id_seq OWNER TO cpde;

--
-- Name: audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;


--
-- Name: client; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.client (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.client FORCE ROW LEVEL SECURITY;


ALTER TABLE public.client OWNER TO cpde;

--
-- Name: COLUMN client.code; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.client.code IS 'Immutable after creation. Engine resolves market_calibration by (client.code, market.code).';


--
-- Name: contract_type; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.contract_type (
    id smallint NOT NULL,
    code text NOT NULL,
    label text NOT NULL,
    engine_value text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.contract_type OWNER TO cpde;

--
-- Name: contract_type_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.contract_type_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.contract_type_id_seq OWNER TO cpde;

--
-- Name: contract_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.contract_type_id_seq OWNED BY public.contract_type.id;


--
-- Name: labor_category; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.labor_category (
    id smallint NOT NULL,
    code text NOT NULL,
    label text NOT NULL,
    category_group text,
    display_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.labor_category OWNER TO cpde;

--
-- Name: labor_category_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.labor_category_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.labor_category_id_seq OWNER TO cpde;

--
-- Name: labor_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.labor_category_id_seq OWNED BY public.labor_category.id;


--
-- Name: market; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.market (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.market FORCE ROW LEVEL SECURITY;


ALTER TABLE public.market OWNER TO cpde;

--
-- Name: opportunity_type; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.opportunity_type (
    id smallint NOT NULL,
    code text NOT NULL,
    label text NOT NULL,
    engine_value text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    type_group text,
    CONSTRAINT opportunity_type_type_group_check CHECK ((type_group = ANY (ARRAY['PRODUCT'::text, 'SERVICES'::text])))
);


ALTER TABLE public.opportunity_type OWNER TO cpde;

--
-- Name: COLUMN opportunity_type.type_group; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.opportunity_type.type_group IS 'PRODUCT = VBA IsDevOrExistingProduct() TRUE. SERVICES = FALSE. Selects which TM1a/TM1b prompt + option set is presented.';


--
-- Name: opportunity_type_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.opportunity_type_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.opportunity_type_id_seq OWNER TO cpde;

--
-- Name: opportunity_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.opportunity_type_id_seq OWNED BY public.opportunity_type.id;


--
-- Name: org_node; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.org_node (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id uuid NOT NULL,
    parent_id uuid,
    node_type text NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_license_boundary boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_org_root CHECK ((((parent_id IS NULL) AND (node_type = 'business'::text)) OR ((parent_id IS NOT NULL) AND (node_type <> 'business'::text)))),
    CONSTRAINT org_node_node_type_check CHECK ((node_type = ANY (ARRAY['business'::text, 'business_unit'::text, 'division'::text])))
);

ALTER TABLE ONLY public.org_node FORCE ROW LEVEL SECURITY;


ALTER TABLE public.org_node OWNER TO cpde;

--
-- Name: COLUMN org_node.is_license_boundary; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.org_node.is_license_boundary IS 'Marks the business_unit level. FLAG ONLY -- no enforcement logic. Licensing is deliberately NOT wired into the access path. See NOTE-2.';


--
-- Name: phase; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.phase (
    id smallint NOT NULL,
    code text NOT NULL,
    label text NOT NULL,
    sequence_no integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.phase OWNER TO cpde;

--
-- Name: phase_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.phase_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.phase_id_seq OWNER TO cpde;

--
-- Name: phase_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.phase_id_seq OWNED BY public.phase.id;


--
-- Name: pipeline_stage; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pipeline_stage (
    id smallint NOT NULL,
    code text NOT NULL,
    label text NOT NULL,
    sequence_no integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.pipeline_stage OWNER TO cpde;

--
-- Name: pipeline_stage_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.pipeline_stage_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pipeline_stage_id_seq OWNER TO cpde;

--
-- Name: pipeline_stage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.pipeline_stage_id_seq OWNED BY public.pipeline_stage.id;


--
-- Name: plan_year; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.plan_year (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    org_node_id uuid NOT NULL,
    calendar_year integer NOT NULL,
    escalation_rate public.rate_frac,
    revenue_target public.money_amt,
    fee_target public.money_amt,
    budgeted_bp public.money_amt,
    budgeted_investment public.money_amt,
    current_contract_revenue public.money_amt,
    current_contract_fee public.money_amt,
    client_id uuid NOT NULL
);

ALTER TABLE ONLY public.plan_year FORCE ROW LEVEL SECURITY;


ALTER TABLE public.plan_year OWNER TO cpde;

--
-- Name: pursuit; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pursuit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id uuid NOT NULL,
    org_node_id uuid NOT NULL,
    external_opportunity_id text,
    name text NOT NULL,
    market_id uuid,
    opportunity_type_id smallint,
    contract_type_id smallint,
    pipeline_stage_id smallint,
    depends_on_pursuit_id uuid,
    is_sole_source boolean DEFAULT false NOT NULL,
    bidders integer,
    bid_decision text,
    planned_total_award_value public.money_amt,
    planned_fee_rate public.rate_frac,
    investment_pct public.rate_frac,
    min_bp public.money_amt,
    max_bp public.money_amt,
    planned_investment public.money_amt,
    bp_start_date date,
    proposal_due_date date,
    contract_award_date date,
    period_end_date date,
    stage_completed_date date,
    cancel_date date,
    outcome text,
    outcome_date date,
    crm_pwin public.pct_prob,
    black_hat_ptw_complete boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT ck_pursuit_dates CHECK ((((proposal_due_date IS NULL) OR (bp_start_date IS NULL) OR (proposal_due_date >= bp_start_date)) AND ((contract_award_date IS NULL) OR (proposal_due_date IS NULL) OR (contract_award_date >= proposal_due_date)) AND ((period_end_date IS NULL) OR (contract_award_date IS NULL) OR (period_end_date >= contract_award_date)))),
    CONSTRAINT ck_pursuit_no_self_dep CHECK ((depends_on_pursuit_id <> id)),
    CONSTRAINT pursuit_bid_decision_check CHECK ((bid_decision = ANY (ARRAY['BID'::text, 'NO_BID'::text, 'UNDECIDED'::text]))),
    CONSTRAINT pursuit_bidders_check CHECK (((bidders IS NULL) OR (bidders >= 1))),
    CONSTRAINT pursuit_outcome_check CHECK ((outcome = ANY (ARRAY['WON'::text, 'LOST'::text, 'CANCELLED'::text, 'NO_BID'::text])))
);

ALTER TABLE ONLY public.pursuit FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pursuit OWNER TO cpde;

--
-- Name: COLUMN pursuit.bidders; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.pursuit.bidders IS 'Competitor COUNT only. Competitor identity is intentionally NOT stored client-side -- supplied to CDA during onboarding. See NOTE-3.';


--
-- Name: pursuit_phase_duration; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pursuit_phase_duration (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pursuit_id uuid NOT NULL,
    phase_id smallint NOT NULL,
    weeks numeric(7,2),
    client_id uuid NOT NULL,
    CONSTRAINT pursuit_phase_duration_weeks_check CHECK ((weeks >= (0)::numeric))
);

ALTER TABLE ONLY public.pursuit_phase_duration FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pursuit_phase_duration OWNER TO cpde;

--
-- Name: pursuit_staffing; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pursuit_staffing (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pursuit_id uuid NOT NULL,
    labor_category_id smallint NOT NULL,
    phase_id smallint NOT NULL,
    fte public.fte_amt DEFAULT 0 NOT NULL,
    client_id uuid NOT NULL
);

ALTER TABLE ONLY public.pursuit_staffing FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pursuit_staffing OWNER TO cpde;

--
-- Name: pursuit_staffing_meta; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pursuit_staffing_meta (
    pursuit_id uuid NOT NULL,
    effective_bp_pct public.rate_frac,
    calculated_bp public.money_amt,
    planned_bp_required public.money_amt,
    calculated_at timestamp with time zone,
    engine_version text,
    client_id uuid
);

ALTER TABLE ONLY public.pursuit_staffing_meta FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pursuit_staffing_meta OWNER TO cpde;

--
-- Name: pursuit_year_projection; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pursuit_year_projection (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pursuit_id uuid NOT NULL,
    year_offset integer NOT NULL,
    calendar_year integer,
    billable_contract_days numeric(9,2),
    probabilistic_revenue public.money_amt,
    probabilistic_fee public.money_amt,
    bp_days numeric(9,2),
    bp_required public.money_amt,
    planned_investment public.money_amt,
    client_id uuid NOT NULL,
    CONSTRAINT pursuit_year_projection_year_offset_check CHECK ((year_offset >= 1))
);

ALTER TABLE ONLY public.pursuit_year_projection FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pursuit_year_projection OWNER TO cpde;

--
-- Name: TABLE pursuit_year_projection; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON TABLE public.pursuit_year_projection IS 'Derived from engine/AOP calculation. year_offset is relative to the planning year. Deliberately unbounded -- the workbook''s hard 5-year limit was a spreadsheet artifact, not a business rule.';


--
-- Name: pwin_answer; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pwin_answer (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pwin_assessment_id uuid NOT NULL,
    question_id uuid NOT NULL,
    question_option_id uuid,
    numeric_value numeric,
    boolean_value boolean,
    client_id uuid NOT NULL,
    CONSTRAINT ck_pwin_answer_one_value CHECK ((((((question_option_id IS NOT NULL))::integer + ((numeric_value IS NOT NULL))::integer) + ((boolean_value IS NOT NULL))::integer) = 1))
);

ALTER TABLE ONLY public.pwin_answer FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pwin_answer OWNER TO cpde;

--
-- Name: pwin_assessment; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.pwin_assessment (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pursuit_id uuid NOT NULL,
    questionnaire_version_id uuid NOT NULL,
    engine_version text NOT NULL,
    calculated_at timestamp with time zone DEFAULT now() NOT NULL,
    calculated_by uuid,
    pwin public.pct_prob,
    base_pwin public.pct_prob,
    score_tech numeric(8,3),
    score_mgmt numeric(8,3),
    score_past_perf numeric(8,3),
    price_position numeric(9,6),
    competitor_price_position numeric(9,6),
    engine_request jsonb,
    engine_response jsonb,
    is_current boolean DEFAULT true NOT NULL,
    scenario text DEFAULT 'BASE'::text NOT NULL,
    blended_pwin public.pct_prob,
    client_id uuid NOT NULL,
    CONSTRAINT pwin_assessment_scenario_check CHECK ((scenario = ANY (ARRAY['BASE'::text, 'DEPENDENT_WON'::text])))
);

ALTER TABLE ONLY public.pwin_assessment FORCE ROW LEVEL SECURITY;


ALTER TABLE public.pwin_assessment OWNER TO cpde;

--
-- Name: TABLE pwin_assessment; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON TABLE public.pwin_assessment IS 'Append-only. Never UPDATE pwin values in place -- insert a new row and flip is_current. Accuracy validation depends on knowing which engine version and questionnaire version produced a given number.';


--
-- Name: COLUMN pwin_assessment.scenario; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.pwin_assessment.scenario IS 'BASE           = standalone assessment (Pursuits Pwins sheet). DEPENDENT_WON  = assessment assuming pursuit.depends_on_pursuit_id                  is won (Pursuits Pwins Dependent sheet). Only pursuits with a dependency have a DEPENDENT_WON row.';


--
-- Name: COLUMN pwin_assessment.blended_pwin; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.pwin_assessment.blended_pwin IS 'Engine output combining BASE and DEPENDENT_WON weighted by the depended-on pursuit''s own Pwin. Recorded on the BASE row. NULL for pursuits with no dependency -- in that case pwin IS the final value.';


--
-- Name: question; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.question (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    questionnaire_version_id uuid NOT NULL,
    code text NOT NULL,
    display_order integer NOT NULL,
    prompt_text text NOT NULL,
    help_text text,
    answer_type text NOT NULL,
    is_required boolean DEFAULT true NOT NULL,
    numeric_min numeric,
    numeric_max numeric,
    section text,
    CONSTRAINT question_answer_type_check CHECK ((answer_type = ANY (ARRAY['single_select'::text, 'numeric'::text, 'boolean'::text])))
);


ALTER TABLE public.question OWNER TO cpde;

--
-- Name: question_dependency; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.question_dependency (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    depends_on_question_id uuid NOT NULL,
    trigger_option_id uuid NOT NULL,
    effect text NOT NULL,
    CONSTRAINT ck_qd_not_self CHECK ((question_id <> depends_on_question_id)),
    CONSTRAINT question_dependency_effect_check CHECK ((effect = ANY (ARRAY['DISABLE'::text, 'HIDE'::text, 'REQUIRE'::text])))
);


ALTER TABLE public.question_dependency OWNER TO cpde;

--
-- Name: TABLE question_dependency; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON TABLE public.question_dependency IS 'Cross-question conditional logic. Currently one known rule: P2 = LPTA disables TM1A and TM1B. Source: PwinForm.frm (CB_TM1a.Enabled = Not isLPTA).';


--
-- Name: question_option; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.question_option (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    code text NOT NULL,
    label_text text NOT NULL,
    engine_value text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    applies_to_type_group text,
    CONSTRAINT question_option_applies_to_type_group_check CHECK ((applies_to_type_group = ANY (ARRAY['PRODUCT'::text, 'SERVICES'::text])))
);


ALTER TABLE public.question_option OWNER TO cpde;

--
-- Name: COLUMN question_option.engine_value; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.question_option.engine_value IS 'The seam. Web app stores option codes; engine receives these strings (e.g. ''4% lower than normal''). Changing the engine contract later means updating this column only -- not every stored answer.';


--
-- Name: COLUMN question_option.applies_to_type_group; Type: COMMENT; Schema: public; Owner: cpde
--

COMMENT ON COLUMN public.question_option.applies_to_type_group IS 'NULL = applies to all opportunity types. Non-null = only shown when the pursuit''s opportunity_type.type_group matches.';


--
-- Name: question_prompt_variant; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.question_prompt_variant (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    type_group text NOT NULL,
    prompt_text text NOT NULL,
    help_text text,
    CONSTRAINT question_prompt_variant_type_group_check CHECK ((type_group = ANY (ARRAY['PRODUCT'::text, 'SERVICES'::text])))
);


ALTER TABLE public.question_prompt_variant OWNER TO cpde;

--
-- Name: questionnaire_version; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.questionnaire_version (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    version_no integer NOT NULL,
    engine_version text,
    effective_from date NOT NULL,
    is_active boolean DEFAULT false NOT NULL,
    notes text
);


ALTER TABLE public.questionnaire_version OWNER TO cpde;

--
-- Name: role; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.role (
    id smallint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    description text
);


ALTER TABLE public.role OWNER TO cpde;

--
-- Name: role_id_seq; Type: SEQUENCE; Schema: public; Owner: cpde
--

CREATE SEQUENCE public.role_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.role_id_seq OWNER TO cpde;

--
-- Name: role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: cpde
--

ALTER SEQUENCE public.role_id_seq OWNED BY public.role.id;


--
-- Name: user_scope_assignment; Type: TABLE; Schema: public; Owner: cpde
--

CREATE TABLE public.user_scope_assignment (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    org_node_id uuid NOT NULL,
    role_id smallint NOT NULL,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    granted_by uuid,
    client_id uuid NOT NULL
);

ALTER TABLE ONLY public.user_scope_assignment FORCE ROW LEVEL SECURITY;


ALTER TABLE public.user_scope_assignment OWNER TO cpde;

--
-- Name: audit_log id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.audit_log ALTER COLUMN id SET DEFAULT nextval('public.audit_log_id_seq'::regclass);


--
-- Name: contract_type id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.contract_type ALTER COLUMN id SET DEFAULT nextval('public.contract_type_id_seq'::regclass);


--
-- Name: labor_category id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.labor_category ALTER COLUMN id SET DEFAULT nextval('public.labor_category_id_seq'::regclass);


--
-- Name: opportunity_type id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.opportunity_type ALTER COLUMN id SET DEFAULT nextval('public.opportunity_type_id_seq'::regclass);


--
-- Name: phase id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.phase ALTER COLUMN id SET DEFAULT nextval('public.phase_id_seq'::regclass);


--
-- Name: pipeline_stage id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pipeline_stage ALTER COLUMN id SET DEFAULT nextval('public.pipeline_stage_id_seq'::regclass);


--
-- Name: role id; Type: DEFAULT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.role ALTER COLUMN id SET DEFAULT nextval('public.role_id_seq'::regclass);


--
-- Data for Name: app_user; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.app_user (id, client_id, email, display_name, is_active, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: audit_log; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.audit_log (id, occurred_at, client_id, user_id, action, table_name, record_id, changed_fields, ip_address, user_agent) FROM stdin;
\.


--
-- Data for Name: client; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.client (id, code, name, is_active, created_at, updated_at) FROM stdin;
339dee6f-1d8f-482c-8465-a87d2650af5e	DEMO	Demo Client	t	2026-08-25 20:26:34.20537+00	2026-08-25 20:26:34.20537+00
\.


--
-- Data for Name: contract_type; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.contract_type (id, code, label, engine_value, display_order, is_active) FROM stdin;
1	COST_PLUS	Cost Plus	Cost Plus	1	t
2	T_AND_M	Time & Materials	Time & Materials	2	t
3	FIXED_PRICE	Fixed Price	Fixed Price	3	t
\.


--
-- Data for Name: labor_category; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.labor_category (id, code, label, category_group, display_order, is_active) FROM stdin;
1	CM	CM	core	1	t
2	TECHLEAD	Tech Lead	core	2	t
3	BDGEN	BD Generalist	core	3	t
4	PROPMGR	Proposal Mgr	core	4	t
5	VOLLEADS	Volume Leads	core	5	t
6	WRITERS	Writers/Editors	core	6	t
7	SMEENG	SMEs (Engineering)	sme	7	t
8	SMEOPS	SMEs (Ops)	sme	8	t
9	SMEPROD	SMEs (Production)	sme	9	t
10	MATLMGR	Mat'l/Subcontract Mgr	core	10	t
11	PRICELEAD	Pricing Lead	core	11	t
12	PRICING	Pricing	core	12	t
13	GRAPHICS	Graphics/Production	core	13	t
14	COMPLIANCE	Compliance	core	14	t
15	REVBLUE	Reviewers (Blue Team)	review	15	t
16	REVPINK	Reviewers (Pink Team)	review	16	t
17	REVRED	Reviewers (Red Team)	review	17	t
18	REVGOLD	Reviewers (Gold Team)	review	18	t
\.


--
-- Data for Name: market; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.market (id, client_id, code, name, display_order, is_active, created_at) FROM stdin;
7e8ac47d-d97a-4e01-982a-022a6b14ed50	339dee6f-1d8f-482c-8465-a87d2650af5e	BMC2A	BMC2A	1	t	2026-08-25 20:26:34.20537+00
99603f5d-e661-4a2f-8fda-38c1c0bc45e1	339dee6f-1d8f-482c-8465-a87d2650af5e	OCS_GENERAL	OCS - General	2	t	2026-08-25 20:26:34.20537+00
9d1fc13e-379b-465e-80a0-cc4213e73e8f	339dee6f-1d8f-482c-8465-a87d2650af5e	OCS_WAVEFORMS	OCS - Waveforms	3	t	2026-08-25 20:26:34.20537+00
\.


--
-- Data for Name: opportunity_type; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.opportunity_type (id, code, label, engine_value, display_order, is_active, type_group) FROM stdin;
1	EXIST_PROD	Existing product solution, little modification required	Existing product solution, little modification required	1	t	PRODUCT
2	DEV_NEW	Developmental/New Product	Developmental/New Product	2	t	PRODUCT
3	ENG_TECH_SVC	Engineering/Technical Services	Engineering/Technical Services	3	t	SERVICES
4	SUSTAIN_OM	Sustainment/O&M	Sustainment/O&M	4	t	SERVICES
\.


--
-- Data for Name: org_node; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.org_node (id, client_id, parent_id, node_type, code, name, is_license_boundary, is_active, created_at, updated_at) FROM stdin;
15eb2e34-06df-4219-8a50-e9cf06b03990	339dee6f-1d8f-482c-8465-a87d2650af5e	\N	business	BUSINESS	Demo Business	f	t	2026-08-25 20:26:34.20537+00	2026-08-25 20:26:34.20537+00
414d69fa-9310-45ed-bed2-ff51d81705d6	339dee6f-1d8f-482c-8465-a87d2650af5e	15eb2e34-06df-4219-8a50-e9cf06b03990	business_unit	BU	Demo BU	t	t	2026-08-25 20:26:34.20537+00	2026-08-25 20:26:34.20537+00
\.


--
-- Data for Name: phase; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.phase (id, code, label, sequence_no, is_active) FROM stdin;
1	STRAT	Strategy	1	t
2	SOL	Solutioning	2	t
3	PREPROP	Pre-Proposal	3	t
4	FINAL	Final Proposal	4	t
5	EN	EN Response	5	t
\.


--
-- Data for Name: pipeline_stage; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pipeline_stage (id, code, label, sequence_no, is_active) FROM stdin;
1	PRE_BH	Pre-BH	1	t
2	POST_BH	Post-BH	2	t
3	POST_PTW	Post-PTW	3	t
\.


--
-- Data for Name: plan_year; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.plan_year (id, org_node_id, calendar_year, escalation_rate, revenue_target, fee_target, budgeted_bp, budgeted_investment, current_contract_revenue, current_contract_fee, client_id) FROM stdin;
9ca6dd83-25d9-4575-a944-301fd8de8386	414d69fa-9310-45ed-bed2-ff51d81705d6	2026	0.028000	40000000.00	3000000.00	3000000.00	1000000.00	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4968aad1-5d75-468b-9f59-75ec89bfc11d	414d69fa-9310-45ed-bed2-ff51d81705d6	2027	0.028000	60000000.00	4000000.00	3250000.00	1200000.00	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
45206b15-fd60-4c80-9635-d552777229a4	414d69fa-9310-45ed-bed2-ff51d81705d6	2028	0.028000	75000000.00	5625000.00	3750000.00	1500000.00	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
50224ed9-4ea7-4a57-a3d9-70ffa34ffb92	414d69fa-9310-45ed-bed2-ff51d81705d6	2029	0.028000	92000000.00	6900000.00	4000000.00	1380000.00	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1cba84ac-6076-4119-b882-8ea4d9a31228	414d69fa-9310-45ed-bed2-ff51d81705d6	2030	0.028000	105000000.00	7875000.00	4250000.00	1050000.00	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: pursuit; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pursuit (id, client_id, org_node_id, external_opportunity_id, name, market_id, opportunity_type_id, contract_type_id, pipeline_stage_id, depends_on_pursuit_id, is_sole_source, bidders, bid_decision, planned_total_award_value, planned_fee_rate, investment_pct, min_bp, max_bp, planned_investment, bp_start_date, proposal_due_date, contract_award_date, period_end_date, stage_completed_date, cancel_date, outcome, outcome_date, crm_pwin, black_hat_ptw_complete, is_active, created_at, created_by, updated_at, updated_by) FROM stdin;
60be7bdc-0f2e-4cc6-b340-89ca684e2705	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	2	Opp 2	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	3	BID	24000000.00	0.025000	0.050000	0.00	0.00	1200000.00	2027-04-03	2027-06-15	2028-10-13	2030-10-08	\N	2026-08-12	CANCELLED	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
009e3647-84a5-42be-b744-db99e853d213	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	3	Manpack	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	2	1	1	\N	f	3	BID	70000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-05-23	2026-11-01	2027-04-30	2030-04-14	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
c6643acf-9962-4fac-8d19-726aa818bbe1	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	11	Opp 11	9d1fc13e-379b-465e-80a0-cc4213e73e8f	1	1	1	\N	f	3	BID	122000000.00	0.045000	0.020000	0.00	0.00	2440000.00	2025-01-20	2025-05-02	2025-10-28	2030-11-02	\N	2026-03-30	LOST	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	6	Opp 6	7e8ac47d-d97a-4e01-982a-022a6b14ed50	3	2	1	\N	f	3	BID	28000000.00	0.090000	0.010000	0.00	0.00	280000.00	2024-10-28	2025-02-01	2025-07-31	2027-07-21	\N	\N	WON	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
4861aa99-4f1c-4d89-adc0-344c5e20a882	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	8	Opp 8	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	3	BID	5000000.00	0.065000	0.000000	0.00	0.00	0.00	2025-02-05	2025-04-01	2025-09-28	2027-08-18	\N	\N	LOST	\N	\N	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
eab754f9-ba9b-4824-8f79-e559ea109ed4	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	9	Opp 9	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	3	3	1	\N	f	3	BID	15000000.00	0.090000	0.000000	0.00	0.00	0.00	2024-05-20	2024-08-16	2024-10-01	2025-10-09	\N	\N	WON	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
107a8b49-cfb7-49d4-a3dd-f45d256664ae	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	4	Opp 4	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	3	1	\N	f	6	BID	12000000.00	0.100000	0.000000	0.00	0.00	0.00	2027-03-30	2027-06-01	2027-11-28	2032-11-02	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
49463a9e-bc7c-4513-930a-23dd60afa6ff	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	16	Opp 16	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	4	1	1	\N	f	3	BID	50000000.00	0.065000	0.000000	0.00	0.00	0.00	2025-03-06	2025-06-12	2025-11-28	2030-11-02	\N	\N	LOST	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
6a7a2c65-ff00-4138-b231-08ef30abbea6	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	1	First Try	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	1	1	1	\N	f	3	BID	1500000.00	0.065000	0.000000	0.00	0.00	0.00	2025-01-15	2025-03-01	2025-08-28	2027-08-18	\N	\N	LOST	\N	0.900000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
4baf4698-bff3-4fc5-b868-f8217875dc44	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	5	Fourth Try	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	1	1	1	\N	f	2	BID	456789852.00	0.065000	0.000000	0.00	0.00	0.00	2026-01-02	2026-05-24	2027-01-12	2032-01-11	\N	\N	\N	\N	\N	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
18150d17-52ca-40d0-9ce8-dd9999cfb8a9	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	10	Opp 10	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	2	1	1	\N	f	2	BID	1100000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-11-27	2027-07-01	2028-05-03	2031-05-02	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
5271fc4f-4383-41d4-a302-70be578956be	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	7	Opp 7	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	1	BID	15000000.00	0.065000	0.000000	0.00	0.00	0.00	2028-05-12	2028-07-16	2029-01-15	2030-01-15	\N	2026-03-11	CANCELLED	\N	\N	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
d88e10f4-ec45-4477-a6e6-d7369eb2dee1	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	30	Opp 30	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	1	1	1	\N	t	1	BID	19000000.00	0.065000	0.000000	0.00	0.00	0.00	2027-11-09	2028-01-18	2028-06-15	2031-06-14	\N	\N	\N	\N	\N	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
17522252-395a-48b6-a72d-f4e3db3df2b4	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	31	Opp 31	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	1	BID	21000000.00	0.065000	0.000000	0.00	0.00	0.00	2024-05-06	2024-07-15	2025-12-15	2030-12-14	\N	\N	WON	\N	0.600000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
fa18eb5b-c301-4e26-93a1-021d57c20c2e	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	35	Opp 35	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	1	1	1	\N	f	1	BID	50000000.00	0.065000	0.000000	0.00	0.00	0.00	2024-09-08	2024-12-01	2025-06-01	2030-05-30	\N	2024-08-03	CANCELLED	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
090d1fef-0165-4070-9abd-589bd74de796	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	54	Opp 54	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	2	1	1	\N	f	3	BID	85000000.00	0.065000	0.035000	0.00	0.00	2975000.00	2024-01-10	2024-06-24	2024-12-08	2028-11-30	\N	\N	WON	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	55	Opp 55	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	1	1	1	\N	f	1	BID	78456123.00	0.095000	0.000000	0.00	0.00	0.00	2027-06-13	2027-09-15	2028-06-01	2031-05-30	\N	\N	\N	\N	\N	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
dd490a38-e5c9-4d91-974c-9bcb31b54ac9	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	60	Final Try	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	4	BID	50000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-12-08	2027-03-02	2027-12-02	2031-06-01	\N	\N	\N	\N	0.300000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
e335d212-f193-47a7-8729-8e81feffec05	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	63	Opp 63	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	2	BID	65468135.00	0.065000	0.035000	0.00	0.00	2291384.73	2028-09-03	2028-12-01	2029-07-01	2033-07-01	\N	\N	\N	\N	0.600000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
cd10c6b3-44f9-42dd-9c13-de9922f60581	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	64	Opp 64	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	2	BID	165968111.00	0.065000	0.000000	0.00	0.00	0.00	2026-09-14	2027-01-01	2027-06-01	2030-12-31	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
abc6a1b9-a813-4f37-8977-a310065f4d59	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	65	Opp 65	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	3	BID	287648392.00	0.065000	0.000000	0.00	0.00	0.00	2025-09-27	2026-02-01	2026-12-01	2030-12-01	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
8335a07b-0017-42a8-85dc-098013d4155d	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	67	opp 67	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	3	BID	6849613.00	0.065000	0.000000	0.00	0.00	0.00	2025-07-05	2025-09-01	2025-12-01	2030-12-01	\N	\N	LOST	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
27069b0b-5405-42ba-885c-4887a2a3ef71	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	68	Opp 68	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	2	\N	f	2	BID	85323322.00	0.045000	0.000000	0.00	0.00	0.00	2025-11-29	2026-03-03	2026-12-20	2030-12-20	2026-03-30	\N	\N	\N	\N	t	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	70	Opp 70	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	3	BID	80000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-10-30	2027-02-01	2027-08-01	2030-07-31	\N	\N	\N	\N	0.300000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
97642c0e-6ff8-4d75-b036-67ec48b7956c	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	71	Opp 71	7e8ac47d-d97a-4e01-982a-022a6b14ed50	4	1	1	\N	f	3	BID	54000000.00	0.065000	0.000000	0.00	0.00	0.00	2027-08-23	2027-12-01	2028-06-01	2032-06-01	\N	\N	\N	\N	0.600000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
66407147-8ee2-4b34-a7e7-45d38c9e35a8	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	72	Opp 72	7e8ac47d-d97a-4e01-982a-022a6b14ed50	1	1	1	\N	f	3	BID	15000000.00	0.065000	0.000000	0.00	0.00	0.00	2027-03-28	2027-06-01	2028-06-01	2032-06-01	\N	\N	\N	\N	0.300000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	TEST-61	Test Pursuit 61	7e8ac47d-d97a-4e01-982a-022a6b14ed50	3	1	1	\N	f	3	BID	10000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-04-29	2026-07-24	2026-11-24	2029-02-24	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	Test-62	Test Pursuit 62	7e8ac47d-d97a-4e01-982a-022a6b14ed50	2	1	1	\N	f	3	BID	80000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-06-20	2026-12-01	2027-06-01	2032-06-01	\N	\N	\N	\N	0.300000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
a0c1f2f8-4877-4828-baf7-e1e6d582b28e	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	73	Opp 73	9d1fc13e-379b-465e-80a0-cc4213e73e8f	3	1	1	\N	f	3	BID	85000000.00	0.065000	0.000000	0.00	0.00	0.00	2026-05-14	2026-09-01	2027-03-01	2030-09-01	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
0645fe54-ce1a-4ed5-b54c-727c2abf3814	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	74	Opp 74	7e8ac47d-d97a-4e01-982a-022a6b14ed50	4	1	1	\N	f	3	BID	7400000.00	0.065000	0.000000	0.00	0.00	0.00	2027-01-21	2027-04-01	2028-01-01	2032-01-01	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
fd6ac260-c2a9-468d-9371-e8715ece7666	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	75	Opp 75	7e8ac47d-d97a-4e01-982a-022a6b14ed50	4	3	1	\N	f	3	BID	6000000.00	0.100000	0.000000	0.00	0.00	0.00	2027-09-24	2027-12-01	2028-06-01	2029-06-01	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
5d1abc42-9e14-47f5-92e8-a3bf03b96072	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	76	Opp 76	7e8ac47d-d97a-4e01-982a-022a6b14ed50	3	3	1	\N	f	3	BID	800000000.00	0.100000	0.000000	0.00	0.00	0.00	2026-05-08	2026-10-01	2027-03-16	2030-03-16	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
5484af78-8853-475b-95c4-e6d48106a41e	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	77	Opp 77	7e8ac47d-d97a-4e01-982a-022a6b14ed50	3	2	1	\N	f	3	BID	79000000.00	0.060000	0.000000	0.00	0.00	0.00	2026-02-11	2026-06-01	2026-12-01	2030-12-01	\N	\N	\N	\N	0.600000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
ca3df605-8cd3-42cd-b7fa-06251da21bef	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	36	Opp 36	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	1	1	1	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	f	3	BID	75000000.00	0.065000	0.000000	0.00	0.00	0.00	2027-09-14	2027-12-15	2028-06-15	2033-06-14	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
94a133f2-836f-4d8e-a401-9cc4a5e341d5	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	53	Opp 53	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	4	2	1	c6643acf-9962-4fac-8d19-726aa818bbe1	f	3	BID	40000000.00	0.110000	0.000000	0.00	0.00	0.00	2026-11-13	2027-02-15	2027-10-15	2030-10-14	\N	\N	\N	\N	0.000000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
7d16a30f-979c-44c3-8784-1045661fa333	339dee6f-1d8f-482c-8465-a87d2650af5e	414d69fa-9310-45ed-bed2-ff51d81705d6	61	Opp 61	99603f5d-e661-4a2f-8fda-38c1c0bc45e1	2	1	1	090d1fef-0165-4070-9abd-589bd74de796	f	3	BID	78879841.00	0.065000	0.020000	0.00	0.00	1577596.82	2027-03-28	2027-09-08	2027-12-31	2032-12-31	\N	\N	\N	\N	0.600000	f	t	2026-08-25 20:26:34.20537+00	\N	2026-08-25 20:26:34.20537+00	\N
\.


--
-- Data for Name: pursuit_phase_duration; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pursuit_phase_duration (id, pursuit_id, phase_id, weeks, client_id) FROM stdin;
fe21e097-d728-4d51-a71f-1bef15f2e003	60be7bdc-0f2e-4cc6-b340-89ca684e2705	1	3.67	339dee6f-1d8f-482c-8465-a87d2650af5e
f4a55090-5251-41ff-b81e-5734472e7bd2	60be7bdc-0f2e-4cc6-b340-89ca684e2705	2	1.84	339dee6f-1d8f-482c-8465-a87d2650af5e
5c3e1ba7-1f28-4ccd-aca9-b3f310d654ce	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	2.43	339dee6f-1d8f-482c-8465-a87d2650af5e
be36dc7a-cd01-459d-b8a7-502334416691	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	2.43	339dee6f-1d8f-482c-8465-a87d2650af5e
a70a6c5a-ca6f-4a20-9d65-2a6482fbda44	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	3.94	339dee6f-1d8f-482c-8465-a87d2650af5e
802161a4-ee9b-4b00-8af7-ba9ae50f6c01	009e3647-84a5-42be-b744-db99e853d213	1	7.86	339dee6f-1d8f-482c-8465-a87d2650af5e
7a0de073-7830-41eb-8ccb-6fedf7cd820c	009e3647-84a5-42be-b744-db99e853d213	2	7.86	339dee6f-1d8f-482c-8465-a87d2650af5e
44f992fa-92e7-4f0f-861d-4bed84352f07	009e3647-84a5-42be-b744-db99e853d213	3	3.72	339dee6f-1d8f-482c-8465-a87d2650af5e
38d71952-d6ec-4923-8485-643962dbbb05	009e3647-84a5-42be-b744-db99e853d213	4	3.72	339dee6f-1d8f-482c-8465-a87d2650af5e
b349fb63-95c0-4a78-b363-4e8429bbe943	009e3647-84a5-42be-b744-db99e853d213	5	7.99	339dee6f-1d8f-482c-8465-a87d2650af5e
7d6f51b1-b37f-495b-8257-0edec2a42c6b	c6643acf-9962-4fac-8d19-726aa818bbe1	1	4.05	339dee6f-1d8f-482c-8465-a87d2650af5e
9b43d889-e4f0-4505-8be3-473aa3e6b567	c6643acf-9962-4fac-8d19-726aa818bbe1	2	2.02	339dee6f-1d8f-482c-8465-a87d2650af5e
647a81f6-08ec-4c61-bdfd-76ff0a895503	c6643acf-9962-4fac-8d19-726aa818bbe1	3	4.29	339dee6f-1d8f-482c-8465-a87d2650af5e
ae60bec8-1446-4214-8dfa-ef81fe004413	c6643acf-9962-4fac-8d19-726aa818bbe1	4	4.29	339dee6f-1d8f-482c-8465-a87d2650af5e
3b5264ae-53e7-4c3a-afff-9b1c6d311405	c6643acf-9962-4fac-8d19-726aa818bbe1	5	4.01	339dee6f-1d8f-482c-8465-a87d2650af5e
89fe242c-badf-482b-b3ef-70904f3460ca	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	3.75	339dee6f-1d8f-482c-8465-a87d2650af5e
982d8341-67b4-417f-92fb-665a75c56d38	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	3.75	339dee6f-1d8f-482c-8465-a87d2650af5e
03d70346-e37b-45b2-9402-1482e3ebba2e	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	3	3.10	339dee6f-1d8f-482c-8465-a87d2650af5e
f8b3ee70-f2bb-4f56-9035-d9becc52c462	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	4	3.10	339dee6f-1d8f-482c-8465-a87d2650af5e
049586d1-0640-4092-83c9-3dec00d1872a	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	5	3.97	339dee6f-1d8f-482c-8465-a87d2650af5e
8534bd92-f321-409d-ad41-f9258aadd071	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	3.34	339dee6f-1d8f-482c-8465-a87d2650af5e
3c1711c9-8c1f-4af5-94e0-09bb9958b8e1	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	1.67	339dee6f-1d8f-482c-8465-a87d2650af5e
4963f8ff-149b-4eea-ac2c-1f192c6d364f	4861aa99-4f1c-4d89-adc0-344c5e20a882	3	1.40	339dee6f-1d8f-482c-8465-a87d2650af5e
b7303446-b026-4183-88c7-3f9131010ec3	4861aa99-4f1c-4d89-adc0-344c5e20a882	4	1.40	339dee6f-1d8f-482c-8465-a87d2650af5e
18fee044-f2c9-4026-8ac8-6fa0a0c11f51	4861aa99-4f1c-4d89-adc0-344c5e20a882	5	3.88	339dee6f-1d8f-482c-8465-a87d2650af5e
d57f2158-ed65-4cd4-8081-7f3953e79dd6	eab754f9-ba9b-4824-8f79-e559ea109ed4	1	3.64	339dee6f-1d8f-482c-8465-a87d2650af5e
b10c83bb-ff95-4a89-99a8-1b5c7d8c689b	eab754f9-ba9b-4824-8f79-e559ea109ed4	2	3.64	339dee6f-1d8f-482c-8465-a87d2650af5e
49f86d6f-2dcf-45e9-930b-0e59990f6b4e	eab754f9-ba9b-4824-8f79-e559ea109ed4	3	2.74	339dee6f-1d8f-482c-8465-a87d2650af5e
8eab55d1-f328-4d61-9dd2-5d04d138582d	eab754f9-ba9b-4824-8f79-e559ea109ed4	4	2.74	339dee6f-1d8f-482c-8465-a87d2650af5e
833035b2-b795-497f-b6a8-70a665a222fc	eab754f9-ba9b-4824-8f79-e559ea109ed4	5	3.96	339dee6f-1d8f-482c-8465-a87d2650af5e
06634582-f920-4985-8a6a-2c5c51a9b8c0	107a8b49-cfb7-49d4-a3dd-f45d256664ae	1	3.52	339dee6f-1d8f-482c-8465-a87d2650af5e
d53978b9-7dec-4e0a-b17c-3f7174689953	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	1.76	339dee6f-1d8f-482c-8465-a87d2650af5e
86aa5f0e-9d75-4cd6-933f-e993b913af29	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	1.90	339dee6f-1d8f-482c-8465-a87d2650af5e
87031d62-fec0-4707-9054-a2b3cd792e6e	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	1.90	339dee6f-1d8f-482c-8465-a87d2650af5e
5e6f27dd-6ae8-44d5-ad70-62a7e7dbcdc1	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	3.92	339dee6f-1d8f-482c-8465-a87d2650af5e
64949b2d-26f3-4c60-9c31-d3410acb985f	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	3.84	339dee6f-1d8f-482c-8465-a87d2650af5e
cd3a5656-c236-45bf-9bcd-1e0128e5baf6	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	3.84	339dee6f-1d8f-482c-8465-a87d2650af5e
4ed7c5bb-223e-44d3-b9e9-16a8e0b8729e	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	3.14	339dee6f-1d8f-482c-8465-a87d2650af5e
b677e954-558d-422e-9ab3-cff5c8e26f55	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	3.14	339dee6f-1d8f-482c-8465-a87d2650af5e
9fbe8697-28e5-44b8-9794-f505c770411a	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	3.97	339dee6f-1d8f-482c-8465-a87d2650af5e
3c043fd6-c9e9-4590-a8b0-cf448015bbb8	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	3.11	339dee6f-1d8f-482c-8465-a87d2650af5e
beeabe6b-1d78-43cc-af9d-dc07fae94f3e	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	1.55	339dee6f-1d8f-482c-8465-a87d2650af5e
04a89241-8a6b-46c9-861b-31ba8c4a237f	6a7a2c65-ff00-4138-b231-08ef30abbea6	3	0.92	339dee6f-1d8f-482c-8465-a87d2650af5e
e2c93409-5d10-469f-9760-804b388619a8	6a7a2c65-ff00-4138-b231-08ef30abbea6	4	0.92	339dee6f-1d8f-482c-8465-a87d2650af5e
95fab432-9ed1-443e-b1d4-21a73616d0f3	6a7a2c65-ff00-4138-b231-08ef30abbea6	5	3.84	339dee6f-1d8f-482c-8465-a87d2650af5e
1ebba878-d62e-4cfd-b49f-def12415559d	4baf4698-bff3-4fc5-b868-f8217875dc44	1	4.38	339dee6f-1d8f-482c-8465-a87d2650af5e
9a0faaf9-0e5f-441b-bc48-0b207c9f5eae	4baf4698-bff3-4fc5-b868-f8217875dc44	2	2.19	339dee6f-1d8f-482c-8465-a87d2650af5e
63dc8dd3-275f-4e9c-8d22-a65b3125e542	4baf4698-bff3-4fc5-b868-f8217875dc44	3	6.81	339dee6f-1d8f-482c-8465-a87d2650af5e
8f000f10-946d-4738-8882-5263d07cb5ac	4baf4698-bff3-4fc5-b868-f8217875dc44	4	6.81	339dee6f-1d8f-482c-8465-a87d2650af5e
968781dd-8825-4b78-9f06-ddba2ee639b8	4baf4698-bff3-4fc5-b868-f8217875dc44	5	4.06	339dee6f-1d8f-482c-8465-a87d2650af5e
d5f6260b-2568-4b57-be08-13ae66328572	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	9.02	339dee6f-1d8f-482c-8465-a87d2650af5e
cfcbcb81-2032-41ff-ac97-5b13408ff87b	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	9.02	339dee6f-1d8f-482c-8465-a87d2650af5e
e5b05cb3-8de0-4482-9042-53b075b4135e	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	6.46	339dee6f-1d8f-482c-8465-a87d2650af5e
ce60cada-be9b-4a9c-a8e6-b33d76a8c31f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	6.46	339dee6f-1d8f-482c-8465-a87d2650af5e
b4584dff-b2e7-456d-bde5-19fcdfe88095	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	8.10	339dee6f-1d8f-482c-8465-a87d2650af5e
385a4bae-b0a9-4b4f-84c2-8f02cece77c7	5271fc4f-4383-41d4-a302-70be578956be	1	3.57	339dee6f-1d8f-482c-8465-a87d2650af5e
138cb677-385b-492e-95e8-a2cfe4dcc86c	5271fc4f-4383-41d4-a302-70be578956be	2	1.78	339dee6f-1d8f-482c-8465-a87d2650af5e
ed4c10e2-723b-45b2-ac3b-b5a4642eb700	5271fc4f-4383-41d4-a302-70be578956be	3	2.06	339dee6f-1d8f-482c-8465-a87d2650af5e
c93b86ee-b2cc-4163-a721-45fbf76df6fb	5271fc4f-4383-41d4-a302-70be578956be	4	2.06	339dee6f-1d8f-482c-8465-a87d2650af5e
ef4b37d8-3375-4389-ba5b-02660e919c77	5271fc4f-4383-41d4-a302-70be578956be	5	3.92	339dee6f-1d8f-482c-8465-a87d2650af5e
e0fb0764-936d-4676-91ff-3a40fa3e60e3	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	1	3.62	339dee6f-1d8f-482c-8465-a87d2650af5e
f8e35975-5c58-48f3-901a-86d0db550c43	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	1.81	339dee6f-1d8f-482c-8465-a87d2650af5e
713fbd99-baa5-4a6c-845c-4322d802a561	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	2.24	339dee6f-1d8f-482c-8465-a87d2650af5e
8cbbe386-9102-4ea2-87a7-674e4ae39117	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	2.24	339dee6f-1d8f-482c-8465-a87d2650af5e
19377056-9587-47b3-bc59-27a59b7e33e7	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	3.93	339dee6f-1d8f-482c-8465-a87d2650af5e
bd9cdaa2-afec-4cb5-880e-4c110cee45c6	17522252-395a-48b6-a72d-f4e3db3df2b4	1	3.64	339dee6f-1d8f-482c-8465-a87d2650af5e
21d73a6e-d9b3-4ae8-88e2-645222956bc9	17522252-395a-48b6-a72d-f4e3db3df2b4	2	1.82	339dee6f-1d8f-482c-8465-a87d2650af5e
44cd37ca-f695-481e-bb0d-2dfee44be98f	17522252-395a-48b6-a72d-f4e3db3df2b4	3	2.32	339dee6f-1d8f-482c-8465-a87d2650af5e
1ee9dbef-2fcf-4248-b4c4-937aa55f26e5	17522252-395a-48b6-a72d-f4e3db3df2b4	4	2.32	339dee6f-1d8f-482c-8465-a87d2650af5e
5068e7b4-37ee-49ae-8122-08d61e7ed406	17522252-395a-48b6-a72d-f4e3db3df2b4	5	3.94	339dee6f-1d8f-482c-8465-a87d2650af5e
26c42f30-223e-4a89-a487-e0f77226cc11	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	3.84	339dee6f-1d8f-482c-8465-a87d2650af5e
4c732392-44cf-4349-8299-8e8430c4d826	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	1.92	339dee6f-1d8f-482c-8465-a87d2650af5e
f743db33-3ca6-4a6e-b44d-26b8ee1767ca	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	3.14	339dee6f-1d8f-482c-8465-a87d2650af5e
84be8783-5078-45f6-8a11-d3bb4a89dc3c	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	3.14	339dee6f-1d8f-482c-8465-a87d2650af5e
14259357-4ee4-4a41-b41d-cecea1742851	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	3.97	339dee6f-1d8f-482c-8465-a87d2650af5e
518c3e22-bfb8-403c-8991-b33f4f2a78fe	ca3df605-8cd3-42cd-b7fa-06251da21bef	1	3.93	339dee6f-1d8f-482c-8465-a87d2650af5e
ab32942c-da06-4962-a771-ba939bbf60af	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	1.97	339dee6f-1d8f-482c-8465-a87d2650af5e
c5e43cb0-cd44-4ed8-862f-b7c30255168e	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	3.62	339dee6f-1d8f-482c-8465-a87d2650af5e
71d56364-ebed-4214-8306-4db09da4276a	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	3.62	339dee6f-1d8f-482c-8465-a87d2650af5e
3e4e831d-16d2-4bf7-9453-0cd5d9c9f2bc	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	3.99	339dee6f-1d8f-482c-8465-a87d2650af5e
f6ac6176-5f59-471c-ac94-3dad6071d0e1	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	3.79	339dee6f-1d8f-482c-8465-a87d2650af5e
e2c6c803-fe63-4699-afda-dbd442e63c2f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	3.79	339dee6f-1d8f-482c-8465-a87d2650af5e
d37330fe-39ac-4385-a355-acffd33037ef	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	2.90	339dee6f-1d8f-482c-8465-a87d2650af5e
2a3f9028-e964-4e4b-8e6e-e3c46bf2feee	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	2.90	339dee6f-1d8f-482c-8465-a87d2650af5e
bfc4abda-2abf-4dbd-96fb-495148535ecc	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	3.96	339dee6f-1d8f-482c-8465-a87d2650af5e
df59e4a4-5e00-4b1d-b49a-a5969226ff38	090d1fef-0165-4070-9abd-589bd74de796	1	7.94	339dee6f-1d8f-482c-8465-a87d2650af5e
2002ae3a-e046-401c-a952-961295481ad8	090d1fef-0165-4070-9abd-589bd74de796	2	7.94	339dee6f-1d8f-482c-8465-a87d2650af5e
3faba6ee-9535-4712-99a4-35bd0a1a3bfa	090d1fef-0165-4070-9abd-589bd74de796	3	3.87	339dee6f-1d8f-482c-8465-a87d2650af5e
6a859d76-75ff-46b7-a069-4b041691f00a	090d1fef-0165-4070-9abd-589bd74de796	4	3.87	339dee6f-1d8f-482c-8465-a87d2650af5e
12197125-0d3b-4f38-ac20-c596c2c69d48	090d1fef-0165-4070-9abd-589bd74de796	5	7.99	339dee6f-1d8f-482c-8465-a87d2650af5e
21da3584-61ff-4e5e-a7b9-f483e7b370be	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	1	3.94	339dee6f-1d8f-482c-8465-a87d2650af5e
b53b6651-6c90-4739-b346-f3574c8ca505	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	1.97	339dee6f-1d8f-482c-8465-a87d2650af5e
0eb3b871-30ab-4cd5-8c20-a597f339bc71	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	3.67	339dee6f-1d8f-482c-8465-a87d2650af5e
0b497249-8e3e-4dbf-adae-d66b583f7c4d	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	3.67	339dee6f-1d8f-482c-8465-a87d2650af5e
0e60233c-d62f-47d2-95a4-d6c4c3c06f8a	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	3.99	339dee6f-1d8f-482c-8465-a87d2650af5e
7d3cf49d-c515-4c31-85ff-52ac6c803f70	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	3.84	339dee6f-1d8f-482c-8465-a87d2650af5e
962f8ae9-4911-43e4-8ee0-f6e6a623d98c	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	1.92	339dee6f-1d8f-482c-8465-a87d2650af5e
5afabef7-21ab-41c1-8563-9c6d88afcf9f	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	3.14	339dee6f-1d8f-482c-8465-a87d2650af5e
2c46ac47-7ad1-40f9-9dc5-00bbd9a436de	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	3.14	339dee6f-1d8f-482c-8465-a87d2650af5e
2b430302-8221-447e-bd11-56f624aef661	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	3.97	339dee6f-1d8f-482c-8465-a87d2650af5e
d43b527f-2322-4b52-9d9a-3d5c5681825d	7d16a30f-979c-44c3-8784-1045661fa333	1	7.91	339dee6f-1d8f-482c-8465-a87d2650af5e
5e010d8c-07d6-4edf-8334-a4e7de7bd540	7d16a30f-979c-44c3-8784-1045661fa333	2	7.91	339dee6f-1d8f-482c-8465-a87d2650af5e
66db4fd3-653b-4340-8573-d1f554f7f248	7d16a30f-979c-44c3-8784-1045661fa333	3	3.81	339dee6f-1d8f-482c-8465-a87d2650af5e
c795b2ee-0c59-4387-83af-f3facb36f525	7d16a30f-979c-44c3-8784-1045661fa333	4	3.81	339dee6f-1d8f-482c-8465-a87d2650af5e
b7510e68-c7d7-423f-8181-ec7769845f89	7d16a30f-979c-44c3-8784-1045661fa333	5	7.99	339dee6f-1d8f-482c-8465-a87d2650af5e
044743d8-255a-44e2-81e2-e3315baf8eb0	e335d212-f193-47a7-8729-8e81feffec05	1	3.90	339dee6f-1d8f-482c-8465-a87d2650af5e
9ddeb6e9-f0b8-4e12-87cb-b83f294b7821	e335d212-f193-47a7-8729-8e81feffec05	2	1.95	339dee6f-1d8f-482c-8465-a87d2650af5e
c74e3fdc-a04c-4651-a871-4d8a11affc02	e335d212-f193-47a7-8729-8e81feffec05	3	3.45	339dee6f-1d8f-482c-8465-a87d2650af5e
c7f8094c-ef70-43d0-a5d5-6d05884d14f3	e335d212-f193-47a7-8729-8e81feffec05	4	3.45	339dee6f-1d8f-482c-8465-a87d2650af5e
6ab7ecee-b1e0-4c46-9c0e-09c202e5903b	e335d212-f193-47a7-8729-8e81feffec05	5	3.98	339dee6f-1d8f-482c-8465-a87d2650af5e
a4cdb726-c11e-495d-ba45-e39a5597a9e6	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	4.12	339dee6f-1d8f-482c-8465-a87d2650af5e
94fa972c-4d6d-4f01-98da-503ab381c133	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	2.06	339dee6f-1d8f-482c-8465-a87d2650af5e
7f0b1f23-77dc-4306-bebf-a898368ee019	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	4.78	339dee6f-1d8f-482c-8465-a87d2650af5e
4e662144-57a9-4243-b0cd-294df98b7922	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	4.78	339dee6f-1d8f-482c-8465-a87d2650af5e
2549e300-5634-45a9-94b7-f3d1e34552db	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	4.02	339dee6f-1d8f-482c-8465-a87d2650af5e
98ad6ada-46b0-40c4-80d4-8c400d71ef03	abc6a1b9-a813-4f37-8977-a310065f4d59	1	4.26	339dee6f-1d8f-482c-8465-a87d2650af5e
4bf72bb1-f846-4fea-9fb9-5bab26b3aac7	abc6a1b9-a813-4f37-8977-a310065f4d59	2	2.13	339dee6f-1d8f-482c-8465-a87d2650af5e
5812a2d5-9165-4b40-9c16-8251699e8a95	abc6a1b9-a813-4f37-8977-a310065f4d59	3	5.79	339dee6f-1d8f-482c-8465-a87d2650af5e
568181b8-1eca-4e31-95b8-b871fa24290c	abc6a1b9-a813-4f37-8977-a310065f4d59	4	5.79	339dee6f-1d8f-482c-8465-a87d2650af5e
946ca140-e0aa-4214-a025-3587acb3b7a2	abc6a1b9-a813-4f37-8977-a310065f4d59	5	4.04	339dee6f-1d8f-482c-8465-a87d2650af5e
d2f7e1bc-bd60-4446-8d2b-59c965fe03e6	8335a07b-0017-42a8-85dc-098013d4155d	1	3.41	339dee6f-1d8f-482c-8465-a87d2650af5e
bde9e3a8-d4ff-4ee6-914b-72824ef58faf	8335a07b-0017-42a8-85dc-098013d4155d	2	1.70	339dee6f-1d8f-482c-8465-a87d2650af5e
8c25b061-440c-41ec-9c90-a43b8cf5e44b	8335a07b-0017-42a8-85dc-098013d4155d	3	1.57	339dee6f-1d8f-482c-8465-a87d2650af5e
14cd1b2e-37de-4b7a-8b26-161040c71097	8335a07b-0017-42a8-85dc-098013d4155d	4	1.57	339dee6f-1d8f-482c-8465-a87d2650af5e
d5381742-924d-4cf3-8ba1-12fd4277fa30	8335a07b-0017-42a8-85dc-098013d4155d	5	3.89	339dee6f-1d8f-482c-8465-a87d2650af5e
bb635e5e-569a-4624-8f04-c84f7d7dfeb1	27069b0b-5405-42ba-885c-4887a2a3ef71	1	3.96	339dee6f-1d8f-482c-8465-a87d2650af5e
6cca6c17-5990-4859-9d45-159fa3445e5f	27069b0b-5405-42ba-885c-4887a2a3ef71	2	1.98	339dee6f-1d8f-482c-8465-a87d2650af5e
68291890-62ef-4b8a-bda7-c6901c85b9c8	27069b0b-5405-42ba-885c-4887a2a3ef71	3	3.78	339dee6f-1d8f-482c-8465-a87d2650af5e
c71edcd6-464d-4fd4-b60f-046f6f000194	27069b0b-5405-42ba-885c-4887a2a3ef71	4	3.78	339dee6f-1d8f-482c-8465-a87d2650af5e
c8b0cc6d-03fb-43d0-8078-1c15c24c5406	27069b0b-5405-42ba-885c-4887a2a3ef71	5	3.99	339dee6f-1d8f-482c-8465-a87d2650af5e
36e36e13-0766-4010-a5a5-60d50eb9f146	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	3.95	339dee6f-1d8f-482c-8465-a87d2650af5e
139a277f-b225-4e24-9d98-5e393e9aab72	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	1.97	339dee6f-1d8f-482c-8465-a87d2650af5e
048f5eeb-1509-4036-bf1e-37691eb86142	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	3.70	339dee6f-1d8f-482c-8465-a87d2650af5e
0a769566-876c-45ec-9a3b-8d3137617a67	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	3.70	339dee6f-1d8f-482c-8465-a87d2650af5e
276176e8-9a1d-4fee-bc84-8a3a1163617e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	3.99	339dee6f-1d8f-482c-8465-a87d2650af5e
e4b87ced-487b-4994-90e8-ccb05010dcd0	97642c0e-6ff8-4d75-b036-67ec48b7956c	1	3.85	339dee6f-1d8f-482c-8465-a87d2650af5e
48e112d0-5363-4f49-8055-8c607be4379b	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	3.85	339dee6f-1d8f-482c-8465-a87d2650af5e
b210b1d6-efc0-4bd6-98a7-5d61d6fcba75	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	3.22	339dee6f-1d8f-482c-8465-a87d2650af5e
724f02e1-1f88-4a85-96d7-98a74764b3f9	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	3.22	339dee6f-1d8f-482c-8465-a87d2650af5e
7d4816e4-2f2a-4385-9c0a-3c62c9763199	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	3.98	339dee6f-1d8f-482c-8465-a87d2650af5e
ecea1411-fad7-4f47-af12-0a9de818f1b8	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	3.57	339dee6f-1d8f-482c-8465-a87d2650af5e
ff49f2b2-0fe4-4599-830c-d0c523021c57	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	3.57	339dee6f-1d8f-482c-8465-a87d2650af5e
bad980ef-296f-4322-baf0-c4d0c005df71	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	2.52	339dee6f-1d8f-482c-8465-a87d2650af5e
aa9ada85-d655-48db-b6ab-aabda406cf28	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	2.52	339dee6f-1d8f-482c-8465-a87d2650af5e
66e882e3-dddf-4afd-8565-bed44ec1c213	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	5	3.95	339dee6f-1d8f-482c-8465-a87d2650af5e
9a110f54-eaa2-4289-b89e-82434b0ce4a7	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	7.91	339dee6f-1d8f-482c-8465-a87d2650af5e
8d682355-0b14-4b0f-a9d4-a87ce3cdf89b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	7.91	339dee6f-1d8f-482c-8465-a87d2650af5e
692777e7-14fc-450e-89c2-4b5f0ce89464	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	3.83	339dee6f-1d8f-482c-8465-a87d2650af5e
691dd8f6-2b7e-4ca4-aabf-018f123bcd89	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	3.83	339dee6f-1d8f-482c-8465-a87d2650af5e
85019936-42fe-476c-b03d-a16178b9287c	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	7.99	339dee6f-1d8f-482c-8465-a87d2650af5e
9d601d2d-67bb-453d-b0fb-c7ca2af6cc3d	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	3.97	339dee6f-1d8f-482c-8465-a87d2650af5e
ea27085a-4a21-44ed-b1ca-10df229aa1b4	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	3.97	339dee6f-1d8f-482c-8465-a87d2650af5e
91073342-67b4-43bc-97d4-8d73748231e7	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	3.87	339dee6f-1d8f-482c-8465-a87d2650af5e
dab40f1b-bd8f-4f0b-ad42-8f843b15fa39	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	3.87	339dee6f-1d8f-482c-8465-a87d2650af5e
0d49a499-e218-48f7-864c-d8b328e59b2e	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	4.00	339dee6f-1d8f-482c-8465-a87d2650af5e
dbb79bfb-ca6f-4e20-a10b-d74d49c9f1bc	0645fe54-ce1a-4ed5-b54c-727c2abf3814	1	3.42	339dee6f-1d8f-482c-8465-a87d2650af5e
eb3ef4aa-d184-4a72-90e1-94a54325608c	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	3.42	339dee6f-1d8f-482c-8465-a87d2650af5e
0fd7cbbb-1303-4595-bf99-b21dde9faef3	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	1.61	339dee6f-1d8f-482c-8465-a87d2650af5e
0909a032-5de2-43f2-bbd3-27872614ae50	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	1.61	339dee6f-1d8f-482c-8465-a87d2650af5e
f04acee9-2dc4-4f9d-8f62-3e5fe410a4b3	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	3.90	339dee6f-1d8f-482c-8465-a87d2650af5e
37b1e8f3-ead7-4b3e-b368-34d0c1cba172	fd6ac260-c2a9-468d-9371-e8715ece7666	1	3.38	339dee6f-1d8f-482c-8465-a87d2650af5e
c7944ba0-8084-4d5a-88c4-c452bc15f619	fd6ac260-c2a9-468d-9371-e8715ece7666	2	3.38	339dee6f-1d8f-482c-8465-a87d2650af5e
4eacbd2f-b07d-41a3-9544-82ef7441e92b	fd6ac260-c2a9-468d-9371-e8715ece7666	3	1.49	339dee6f-1d8f-482c-8465-a87d2650af5e
c18e3862-024e-4d5a-b7c0-7b3e3e15e6e7	fd6ac260-c2a9-468d-9371-e8715ece7666	4	1.49	339dee6f-1d8f-482c-8465-a87d2650af5e
9a701b5f-22fc-4867-8c6a-b8c2cd046603	fd6ac260-c2a9-468d-9371-e8715ece7666	5	3.89	339dee6f-1d8f-482c-8465-a87d2650af5e
6e5f4273-0dea-4e68-8afa-6abc9b3f8414	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	4.44	339dee6f-1d8f-482c-8465-a87d2650af5e
f3f2538f-bf06-4b50-8909-3834ce3459f2	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	4.44	339dee6f-1d8f-482c-8465-a87d2650af5e
216dbe49-407f-4159-aef6-86c255aef76f	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	6.06	339dee6f-1d8f-482c-8465-a87d2650af5e
6ddd6dfc-90d9-4c77-8506-f9ed28d08403	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	6.06	339dee6f-1d8f-482c-8465-a87d2650af5e
173fde20-7c28-4a48-9ffd-052ccae34ae9	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	4.04	339dee6f-1d8f-482c-8465-a87d2650af5e
414e944e-679b-4268-a2ac-12b84450bb0d	5484af78-8853-475b-95c4-e6d48106a41e	1	3.95	339dee6f-1d8f-482c-8465-a87d2650af5e
be9759a0-5b3b-44ef-b9e9-3da838133998	5484af78-8853-475b-95c4-e6d48106a41e	2	3.95	339dee6f-1d8f-482c-8465-a87d2650af5e
3bfb093f-2747-48a2-997d-0e19ffaa295a	5484af78-8853-475b-95c4-e6d48106a41e	3	3.82	339dee6f-1d8f-482c-8465-a87d2650af5e
a8c97307-f471-409a-91b9-7a89ca22dfea	5484af78-8853-475b-95c4-e6d48106a41e	4	3.82	339dee6f-1d8f-482c-8465-a87d2650af5e
8a677a1b-c6ac-4200-8a46-2c6b27972aa1	5484af78-8853-475b-95c4-e6d48106a41e	5	4.00	339dee6f-1d8f-482c-8465-a87d2650af5e
5b102d01-36fe-4952-b281-a8cf39413224	66407147-8ee2-4b34-a7e7-45d38c9e35a8	1	3.57	339dee6f-1d8f-482c-8465-a87d2650af5e
63712a7d-82d8-42c3-b21c-5f69ea6efc66	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	1.78	339dee6f-1d8f-482c-8465-a87d2650af5e
7f17e21f-bb87-41b6-a19a-17e01ffea8f5	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	2.06	339dee6f-1d8f-482c-8465-a87d2650af5e
0af6e0aa-73c4-4c49-9cfe-fead40b988d1	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	2.06	339dee6f-1d8f-482c-8465-a87d2650af5e
3bf19c9a-9634-4088-adcd-0ecba7512636	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	3.92	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: pursuit_staffing; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pursuit_staffing (id, pursuit_id, labor_category_id, phase_id, fte, client_id) FROM stdin;
702229c9-d3bb-4ebe-945e-1e0d65468201	60be7bdc-0f2e-4cc6-b340-89ca684e2705	1	1	0.268	339dee6f-1d8f-482c-8465-a87d2650af5e
833a98dd-d5b3-4345-a795-7b08fcc3da4a	60be7bdc-0f2e-4cc6-b340-89ca684e2705	1	2	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
296bc677-8116-42cd-8a1b-e355cc033818	60be7bdc-0f2e-4cc6-b340-89ca684e2705	1	3	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
2cb86961-ca3a-49e4-a9fb-c65a72188fd8	60be7bdc-0f2e-4cc6-b340-89ca684e2705	1	4	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
df8d47d3-38cd-4bc2-8fd8-c77b417d6bf9	60be7bdc-0f2e-4cc6-b340-89ca684e2705	1	5	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
65702139-75ad-43b5-95cf-c28d4d3dbc97	60be7bdc-0f2e-4cc6-b340-89ca684e2705	2	1	0.268	339dee6f-1d8f-482c-8465-a87d2650af5e
3a8c36ce-27de-440e-ab1c-4cdc016c1bcd	60be7bdc-0f2e-4cc6-b340-89ca684e2705	2	2	0.402	339dee6f-1d8f-482c-8465-a87d2650af5e
261506bd-fef4-4e5e-bed8-88d11628ed7d	60be7bdc-0f2e-4cc6-b340-89ca684e2705	2	3	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
25997205-a123-44fc-932a-8d4413f65795	60be7bdc-0f2e-4cc6-b340-89ca684e2705	2	4	0.402	339dee6f-1d8f-482c-8465-a87d2650af5e
7f69dfcb-7c0b-4ccc-a017-0bbac7c03eeb	60be7bdc-0f2e-4cc6-b340-89ca684e2705	2	5	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
c005e085-c91c-4783-bfaf-3b22dbe69acc	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	1	0.077	339dee6f-1d8f-482c-8465-a87d2650af5e
b311d2f9-622e-4a36-8dbb-405055a6474f	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	2	0.092	339dee6f-1d8f-482c-8465-a87d2650af5e
e6abbfbe-d89c-4b8c-b5f9-a2a424c75ee8	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d119234c-fa5d-443f-923e-f5ca6f90f146	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
10c5b40e-0649-49fb-8f66-804117859359	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0ab9bef5-4982-4d8f-96cc-07fec1033ac3	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d142c232-adc3-47c0-86a9-299f72bcf77b	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	2	0.268	339dee6f-1d8f-482c-8465-a87d2650af5e
65cdaaa0-89c3-40af-a1c9-6fdf5a7457d9	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	3	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
66d5d92f-e6c1-455f-92e5-4996ebe79e68	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	4	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
79d2708a-961e-45e0-87cf-3d18896bc8c6	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	5	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
489be965-390b-4386-a9bf-9524eb19c6d3	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1883cf38-0ebf-44c8-9eda-311e722e4a5f	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	2	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
9a38be8c-9e2f-4676-927a-2b620271612a	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	3	1.073	339dee6f-1d8f-482c-8465-a87d2650af5e
ac7c815c-5dd4-4314-92a6-2e6938366a9b	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	4	1.073	339dee6f-1d8f-482c-8465-a87d2650af5e
78d67b3b-7ad4-46cb-ad50-3408335e91fa	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	5	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
2bcc7d49-c46f-4a5b-a212-39ccbd5c0ece	60be7bdc-0f2e-4cc6-b340-89ca684e2705	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e1380bad-8112-4d31-9c62-2fe81af83e95	60be7bdc-0f2e-4cc6-b340-89ca684e2705	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b22b3b0-eb32-44e0-aa76-43b89c8b9708	60be7bdc-0f2e-4cc6-b340-89ca684e2705	6	3	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
7645b45c-0163-4e74-bbfb-9182710dc069	60be7bdc-0f2e-4cc6-b340-89ca684e2705	6	4	0.919	339dee6f-1d8f-482c-8465-a87d2650af5e
6b0c7ace-a80e-44d5-b3ad-68d7aa37d436	60be7bdc-0f2e-4cc6-b340-89ca684e2705	6	5	0.077	339dee6f-1d8f-482c-8465-a87d2650af5e
330ae7ec-2e1c-4e5b-a29c-2dcccde3d061	60be7bdc-0f2e-4cc6-b340-89ca684e2705	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1849e400-46f9-487d-ba01-c7ebcbb2604b	60be7bdc-0f2e-4cc6-b340-89ca684e2705	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
99393f0a-ae45-4211-a2c6-9df1d53ebe77	60be7bdc-0f2e-4cc6-b340-89ca684e2705	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
94f591d1-08e1-4800-8e8b-3c40125de4a2	60be7bdc-0f2e-4cc6-b340-89ca684e2705	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0a92f756-3b84-4c89-9930-e2301e6aefb2	60be7bdc-0f2e-4cc6-b340-89ca684e2705	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
85984d2c-9cbe-4069-b127-37d9be02b541	60be7bdc-0f2e-4cc6-b340-89ca684e2705	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6b0c21f-2fb6-4741-a5c2-0d529c955367	60be7bdc-0f2e-4cc6-b340-89ca684e2705	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b0e1f1b-d9ff-4f96-9eac-4dec9b7178a6	60be7bdc-0f2e-4cc6-b340-89ca684e2705	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ed77726c-d4d7-4df4-92a4-fb72fca5a593	60be7bdc-0f2e-4cc6-b340-89ca684e2705	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a944fe8e-61b6-4b2b-88bd-ed5b4036e103	60be7bdc-0f2e-4cc6-b340-89ca684e2705	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b5f15bab-cfa5-4ba5-8a10-e370f556174a	60be7bdc-0f2e-4cc6-b340-89ca684e2705	9	1	0.230	339dee6f-1d8f-482c-8465-a87d2650af5e
5ed1ae3b-b613-4af6-bd04-14c4ff9aeef1	60be7bdc-0f2e-4cc6-b340-89ca684e2705	9	2	0.383	339dee6f-1d8f-482c-8465-a87d2650af5e
8715d2d9-359e-40c5-a746-6fd72d2e0d75	60be7bdc-0f2e-4cc6-b340-89ca684e2705	9	3	0.766	339dee6f-1d8f-482c-8465-a87d2650af5e
57c68152-c741-4a27-b3ce-efc65ffc3cb5	60be7bdc-0f2e-4cc6-b340-89ca684e2705	9	4	0.306	339dee6f-1d8f-482c-8465-a87d2650af5e
7e57afdd-30d5-4b3d-8f1f-156503474f3e	60be7bdc-0f2e-4cc6-b340-89ca684e2705	9	5	0.153	339dee6f-1d8f-482c-8465-a87d2650af5e
b46c55fb-6f24-478a-8f98-de3884a6ba09	60be7bdc-0f2e-4cc6-b340-89ca684e2705	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a0bd519d-2abe-4efe-aab8-62469f86eaca	60be7bdc-0f2e-4cc6-b340-89ca684e2705	10	2	0.153	339dee6f-1d8f-482c-8465-a87d2650af5e
daefb550-1e93-4071-9ca9-107fc9e83055	60be7bdc-0f2e-4cc6-b340-89ca684e2705	10	3	0.306	339dee6f-1d8f-482c-8465-a87d2650af5e
966da4ac-1b94-4ddf-b30a-31ac8c6f13a2	60be7bdc-0f2e-4cc6-b340-89ca684e2705	10	4	0.306	339dee6f-1d8f-482c-8465-a87d2650af5e
1ff40efc-92bb-4efe-8f6a-98b6acfa5ed3	60be7bdc-0f2e-4cc6-b340-89ca684e2705	10	5	0.077	339dee6f-1d8f-482c-8465-a87d2650af5e
8dc392bd-6a8f-406b-8d24-f54f690eaa69	60be7bdc-0f2e-4cc6-b340-89ca684e2705	11	1	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
eba0b514-074c-4c99-91dd-1b90685f0a81	60be7bdc-0f2e-4cc6-b340-89ca684e2705	11	2	0.215	339dee6f-1d8f-482c-8465-a87d2650af5e
ac6332ea-43a2-4030-8256-0f8cad238c25	60be7bdc-0f2e-4cc6-b340-89ca684e2705	11	3	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
72da88fa-c595-462d-979a-912c42ce844e	60be7bdc-0f2e-4cc6-b340-89ca684e2705	11	4	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
8b7d42bf-af8a-4978-a3a3-beec9aeb81ea	60be7bdc-0f2e-4cc6-b340-89ca684e2705	11	5	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
1b78f0e2-f66b-4bd7-9e93-a21810c267d3	60be7bdc-0f2e-4cc6-b340-89ca684e2705	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1578507c-028f-4002-abec-c5c2b87e964a	60be7bdc-0f2e-4cc6-b340-89ca684e2705	12	2	0.153	339dee6f-1d8f-482c-8465-a87d2650af5e
89ec1d20-3262-429f-ae22-3d7e7cc9368e	60be7bdc-0f2e-4cc6-b340-89ca684e2705	12	3	0.613	339dee6f-1d8f-482c-8465-a87d2650af5e
cefbc415-0dcd-4cac-84ec-306385edd3b7	60be7bdc-0f2e-4cc6-b340-89ca684e2705	12	4	0.613	339dee6f-1d8f-482c-8465-a87d2650af5e
74926a63-e82b-452b-98bd-4395d720ea7b	60be7bdc-0f2e-4cc6-b340-89ca684e2705	12	5	0.096	339dee6f-1d8f-482c-8465-a87d2650af5e
20f6e2c7-8a58-4a79-8483-4293d32d35ba	60be7bdc-0f2e-4cc6-b340-89ca684e2705	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5aa2e12d-fa17-4c22-a898-8eaf60de04fb	60be7bdc-0f2e-4cc6-b340-89ca684e2705	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3e709a5a-2165-4282-9511-4692dec4a6f0	60be7bdc-0f2e-4cc6-b340-89ca684e2705	13	3	0.460	339dee6f-1d8f-482c-8465-a87d2650af5e
6b1ef2d6-c4df-4794-a7d1-26a0c61b9a19	60be7bdc-0f2e-4cc6-b340-89ca684e2705	13	4	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
4de72540-9c25-415b-81b0-c2da33bcdcc4	60be7bdc-0f2e-4cc6-b340-89ca684e2705	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bb1ce49b-8edc-4722-8253-24790e7220e1	60be7bdc-0f2e-4cc6-b340-89ca684e2705	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
94d89e6c-6c0d-4823-98bf-9f9f5b4bde10	60be7bdc-0f2e-4cc6-b340-89ca684e2705	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
41cddaef-26ac-4ba4-8058-43545df9e973	60be7bdc-0f2e-4cc6-b340-89ca684e2705	14	3	0.057	339dee6f-1d8f-482c-8465-a87d2650af5e
9e2ba627-dbf0-4f59-9f4b-41324fb21ce9	60be7bdc-0f2e-4cc6-b340-89ca684e2705	14	4	0.057	339dee6f-1d8f-482c-8465-a87d2650af5e
211a28f8-b10b-4c66-8f84-490842e27231	60be7bdc-0f2e-4cc6-b340-89ca684e2705	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0c620caf-b11d-4238-9bab-e69d4f3b58ae	60be7bdc-0f2e-4cc6-b340-89ca684e2705	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4729fcd3-ff50-4e3c-a6eb-958bbe42b0eb	60be7bdc-0f2e-4cc6-b340-89ca684e2705	15	2	0.153	339dee6f-1d8f-482c-8465-a87d2650af5e
abd39830-9460-4163-84dd-bbf4f1a719b5	60be7bdc-0f2e-4cc6-b340-89ca684e2705	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
19473741-e109-4f64-9cce-dd65230a1f9e	60be7bdc-0f2e-4cc6-b340-89ca684e2705	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f4616478-95f8-40cb-b4dd-879a4ca9b53e	60be7bdc-0f2e-4cc6-b340-89ca684e2705	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
29aae4b2-7a06-4a32-b38c-4545762cc80d	60be7bdc-0f2e-4cc6-b340-89ca684e2705	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
740aa8cf-9059-4983-bc5d-4f08f6cc3643	60be7bdc-0f2e-4cc6-b340-89ca684e2705	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c86d20a6-68ec-4fd1-9f1e-3c63b688fae6	60be7bdc-0f2e-4cc6-b340-89ca684e2705	16	3	0.092	339dee6f-1d8f-482c-8465-a87d2650af5e
f09bff62-2293-428e-86cc-d3a2115ea207	60be7bdc-0f2e-4cc6-b340-89ca684e2705	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1f8564c4-e6cc-4648-9cb9-7239c90f8ebb	60be7bdc-0f2e-4cc6-b340-89ca684e2705	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7bc8fde0-59dc-4a02-870e-bf3494b18476	60be7bdc-0f2e-4cc6-b340-89ca684e2705	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b709bb18-cee8-476d-a776-6cf92056e65c	60be7bdc-0f2e-4cc6-b340-89ca684e2705	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e45d3377-473d-46c2-a58b-73ade5dd98f0	60be7bdc-0f2e-4cc6-b340-89ca684e2705	17	3	0.115	339dee6f-1d8f-482c-8465-a87d2650af5e
4547f1ce-86fd-436e-8091-4d32a703507c	60be7bdc-0f2e-4cc6-b340-89ca684e2705	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1fc891b1-6647-40ab-9d0e-2366dde1604f	60be7bdc-0f2e-4cc6-b340-89ca684e2705	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b0831291-2545-49b3-ad70-c2f2b90bb3d4	60be7bdc-0f2e-4cc6-b340-89ca684e2705	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d82008f6-d193-4199-bccd-77be99629e67	60be7bdc-0f2e-4cc6-b340-89ca684e2705	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
45ecf894-1dc3-416b-95a6-5fca931b43d8	60be7bdc-0f2e-4cc6-b340-89ca684e2705	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
961fd8ef-3aed-40f6-8060-b11789c643c8	60be7bdc-0f2e-4cc6-b340-89ca684e2705	18	4	0.115	339dee6f-1d8f-482c-8465-a87d2650af5e
ea454a89-4947-4960-a97f-59333b867fd5	60be7bdc-0f2e-4cc6-b340-89ca684e2705	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1ba5ec40-9d38-4cb2-9d92-8c23886ec80e	009e3647-84a5-42be-b744-db99e853d213	1	1	0.636	339dee6f-1d8f-482c-8465-a87d2650af5e
1b521483-b59b-4498-af94-3bdb9c647397	009e3647-84a5-42be-b744-db99e853d213	1	2	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
999c14ac-775e-4e2f-8a33-cb1bcdbf9376	009e3647-84a5-42be-b744-db99e853d213	1	3	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
dbb64eb2-196a-42f1-b0be-d0eb165f3553	009e3647-84a5-42be-b744-db99e853d213	1	4	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
230d97c9-7eed-45c8-84af-e1060f958738	009e3647-84a5-42be-b744-db99e853d213	1	5	0.424	339dee6f-1d8f-482c-8465-a87d2650af5e
79fdac5d-e79f-4fe8-8b53-e01c2a4ab34e	009e3647-84a5-42be-b744-db99e853d213	2	1	0.636	339dee6f-1d8f-482c-8465-a87d2650af5e
1561f9a2-831b-4614-9881-c50564e036d6	009e3647-84a5-42be-b744-db99e853d213	2	2	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
000e0c84-4a33-42d3-b8cb-0c2f67d70841	009e3647-84a5-42be-b744-db99e853d213	2	3	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
d1a34156-d885-4709-99ba-6c3faa98766c	009e3647-84a5-42be-b744-db99e853d213	2	4	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
8e0c9f47-9f42-414a-ac51-8b590ab73c1f	009e3647-84a5-42be-b744-db99e853d213	2	5	0.424	339dee6f-1d8f-482c-8465-a87d2650af5e
88d75557-9250-4c46-a92f-9ca4e29fd172	009e3647-84a5-42be-b744-db99e853d213	3	1	0.778	339dee6f-1d8f-482c-8465-a87d2650af5e
54dfbd64-a37b-4420-a01b-56936792fbca	009e3647-84a5-42be-b744-db99e853d213	3	2	0.389	339dee6f-1d8f-482c-8465-a87d2650af5e
8c8b6a29-5550-46f5-89b6-4bea26f0aa15	009e3647-84a5-42be-b744-db99e853d213	3	3	0.389	339dee6f-1d8f-482c-8465-a87d2650af5e
7c981d21-5861-47ce-afe1-f8209a4858d0	009e3647-84a5-42be-b744-db99e853d213	3	4	0.389	339dee6f-1d8f-482c-8465-a87d2650af5e
2a2653b9-4016-4fbd-831a-089bd6e55089	009e3647-84a5-42be-b744-db99e853d213	3	5	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
e1d89d43-d6b1-4fc7-a6b5-775657f7930d	009e3647-84a5-42be-b744-db99e853d213	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4501fa15-3cbb-4b13-a29f-6cbaab1401c3	009e3647-84a5-42be-b744-db99e853d213	4	2	0.424	339dee6f-1d8f-482c-8465-a87d2650af5e
d126305f-ac7a-449c-b6ff-84fdc5d0fe82	009e3647-84a5-42be-b744-db99e853d213	4	3	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
4c3bc769-0839-456e-bb0b-e3aad75e8590	009e3647-84a5-42be-b744-db99e853d213	4	4	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
cb6fcf0b-9ee1-470c-8d6a-3df06f5565ac	009e3647-84a5-42be-b744-db99e853d213	4	5	0.212	339dee6f-1d8f-482c-8465-a87d2650af5e
d9fa680a-eb4f-4563-bbc9-673acd91c63e	009e3647-84a5-42be-b744-db99e853d213	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b0026964-a740-487f-a579-e6b2c40b0bd4	009e3647-84a5-42be-b744-db99e853d213	5	2	1.272	339dee6f-1d8f-482c-8465-a87d2650af5e
f713256e-ad1d-4a0e-9752-fa42e7e7e42e	009e3647-84a5-42be-b744-db99e853d213	5	3	2.544	339dee6f-1d8f-482c-8465-a87d2650af5e
61507f62-0159-4a69-9d48-5d51ae4a88bf	009e3647-84a5-42be-b744-db99e853d213	5	4	2.544	339dee6f-1d8f-482c-8465-a87d2650af5e
7f509b0b-b93d-4d3f-81a3-c2bf3515e6b9	009e3647-84a5-42be-b744-db99e853d213	5	5	0.636	339dee6f-1d8f-482c-8465-a87d2650af5e
55409847-cf18-4110-bf50-55d1c3423218	009e3647-84a5-42be-b744-db99e853d213	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
999dcdc5-361c-4a6c-a538-40f40de4eb44	009e3647-84a5-42be-b744-db99e853d213	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32759ff5-e0c7-4b39-b467-bdf3908ff5f1	009e3647-84a5-42be-b744-db99e853d213	6	3	5.056	339dee6f-1d8f-482c-8465-a87d2650af5e
7359d951-ae81-4471-9c74-d9bc769e7df4	009e3647-84a5-42be-b744-db99e853d213	6	4	5.834	339dee6f-1d8f-482c-8465-a87d2650af5e
2b5a4fee-b8c1-4d29-bf43-b6c2c3165657	009e3647-84a5-42be-b744-db99e853d213	6	5	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
a0b06a21-b915-4e76-90ad-3a7fc9632833	009e3647-84a5-42be-b744-db99e853d213	7	1	0.681	339dee6f-1d8f-482c-8465-a87d2650af5e
0248104f-305a-48a6-bda1-3184bbf51ca8	009e3647-84a5-42be-b744-db99e853d213	7	2	3.501	339dee6f-1d8f-482c-8465-a87d2650af5e
72e49d57-6043-4791-b96f-9128d1075b06	009e3647-84a5-42be-b744-db99e853d213	7	3	1.945	339dee6f-1d8f-482c-8465-a87d2650af5e
d7b997b0-0ac7-4288-b600-ded9c122a4a6	009e3647-84a5-42be-b744-db99e853d213	7	4	0.972	339dee6f-1d8f-482c-8465-a87d2650af5e
7db6179a-e46d-4a5c-afff-f3a4361f6c16	009e3647-84a5-42be-b744-db99e853d213	7	5	0.389	339dee6f-1d8f-482c-8465-a87d2650af5e
4b5dbcc1-b9f1-4e66-a7a5-61c83875f530	009e3647-84a5-42be-b744-db99e853d213	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5badcff0-a5c1-44d8-9810-7c32c005da27	009e3647-84a5-42be-b744-db99e853d213	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5238b82f-9633-4dce-9472-a106514b5fd9	009e3647-84a5-42be-b744-db99e853d213	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4fd2b791-76b9-4dca-b1c6-839d6b0a7041	009e3647-84a5-42be-b744-db99e853d213	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
98ec0a92-7574-4a35-982f-cb10d657a678	009e3647-84a5-42be-b744-db99e853d213	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1d5413d9-255d-4313-a1da-428bf3c8c9df	009e3647-84a5-42be-b744-db99e853d213	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a92d6466-eb81-44a4-8ae4-fbf964d3a174	009e3647-84a5-42be-b744-db99e853d213	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a73af35f-6d2b-437c-9829-f4236720a74e	009e3647-84a5-42be-b744-db99e853d213	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2e3f1ed6-7b66-4a8a-85cc-ff980cd9f875	009e3647-84a5-42be-b744-db99e853d213	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dd8e734c-47cc-404d-a9da-cce08807226e	009e3647-84a5-42be-b744-db99e853d213	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3bdd6ddc-db7d-4fd0-8375-faeecb101769	009e3647-84a5-42be-b744-db99e853d213	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
efdc179e-3b56-450c-8277-352b39e7106a	009e3647-84a5-42be-b744-db99e853d213	10	2	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
08acd32a-a50b-4261-ae39-4177f4af1689	009e3647-84a5-42be-b744-db99e853d213	10	3	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
bebcddca-4408-406d-970b-acbba3e879eb	009e3647-84a5-42be-b744-db99e853d213	10	4	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
eaeb7eaf-b5a2-4bde-a1b9-27ce6af885bb	009e3647-84a5-42be-b744-db99e853d213	10	5	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
b531f6fc-e41c-42c4-ac54-da71ad7f358d	009e3647-84a5-42be-b744-db99e853d213	11	1	0.212	339dee6f-1d8f-482c-8465-a87d2650af5e
2ea519ac-1ca7-480f-9b7d-cf3e577ac460	009e3647-84a5-42be-b744-db99e853d213	11	2	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
c3087521-7404-410d-b9ef-76f2b33f8436	009e3647-84a5-42be-b744-db99e853d213	11	3	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
85690eb0-155c-4551-b512-ef5cf8ac8551	009e3647-84a5-42be-b744-db99e853d213	11	4	0.848	339dee6f-1d8f-482c-8465-a87d2650af5e
c8c8d9d9-7c54-4c93-85fc-4f282e68d1a6	009e3647-84a5-42be-b744-db99e853d213	11	5	0.212	339dee6f-1d8f-482c-8465-a87d2650af5e
281c1cdb-fc69-473a-9775-fc66bfa31956	009e3647-84a5-42be-b744-db99e853d213	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74be2333-9809-4b61-921c-6539ca892b9c	009e3647-84a5-42be-b744-db99e853d213	12	2	1.556	339dee6f-1d8f-482c-8465-a87d2650af5e
c553b174-1f9c-4b15-b8b2-fe9084f913c0	009e3647-84a5-42be-b744-db99e853d213	12	3	3.112	339dee6f-1d8f-482c-8465-a87d2650af5e
3d498959-5d74-4548-b5cb-f0b8b993d944	009e3647-84a5-42be-b744-db99e853d213	12	4	3.889	339dee6f-1d8f-482c-8465-a87d2650af5e
b1e307ee-ff10-48c5-ba66-78e8b341423e	009e3647-84a5-42be-b744-db99e853d213	12	5	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
53a2c10d-9128-45cf-ba84-becda2db14a9	009e3647-84a5-42be-b744-db99e853d213	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
75125484-c867-4349-a2b8-1f10d5a92ba0	009e3647-84a5-42be-b744-db99e853d213	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
52723a6d-e4ba-4217-81c8-c2630f5af37e	009e3647-84a5-42be-b744-db99e853d213	13	3	2.334	339dee6f-1d8f-482c-8465-a87d2650af5e
3f27d688-5979-4645-a799-f3d76cd08547	009e3647-84a5-42be-b744-db99e853d213	13	4	3.889	339dee6f-1d8f-482c-8465-a87d2650af5e
fcdc2303-251c-459a-b74b-675e306f4cfd	009e3647-84a5-42be-b744-db99e853d213	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
675f5c24-4be1-41c2-800a-3013aa1e2387	009e3647-84a5-42be-b744-db99e853d213	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
95ca9f18-38d1-4359-9202-86c7871b1bed	009e3647-84a5-42be-b744-db99e853d213	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
329bb970-bfc9-4f14-bf6d-d3e2637d1ba4	009e3647-84a5-42be-b744-db99e853d213	14	3	0.583	339dee6f-1d8f-482c-8465-a87d2650af5e
3d978124-9ff1-46ff-bf9c-1083b7304c4b	009e3647-84a5-42be-b744-db99e853d213	14	4	0.583	339dee6f-1d8f-482c-8465-a87d2650af5e
0670d4e2-ac73-4d90-ac16-3f4f4c32ece4	009e3647-84a5-42be-b744-db99e853d213	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
776deb0f-4731-49d9-98ff-974c3f8e52fe	009e3647-84a5-42be-b744-db99e853d213	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fc45814d-c0fc-409c-ae89-1b9be551940f	009e3647-84a5-42be-b744-db99e853d213	15	2	0.438	339dee6f-1d8f-482c-8465-a87d2650af5e
33a82571-e9dc-4e82-a0c5-42de3d275e4c	009e3647-84a5-42be-b744-db99e853d213	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
45fe3324-56f5-4ec4-b0c8-71ee78f4e101	009e3647-84a5-42be-b744-db99e853d213	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0fcd212a-711c-4dac-bacf-5402fcd6f5b0	009e3647-84a5-42be-b744-db99e853d213	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2713803b-9d9d-44b7-a5fb-e27ddf63f301	009e3647-84a5-42be-b744-db99e853d213	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0696282f-38f6-4be7-a926-c50760780cf6	009e3647-84a5-42be-b744-db99e853d213	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ca8a2e55-1d9a-4d0b-a601-e5aa297bae95	009e3647-84a5-42be-b744-db99e853d213	16	3	0.875	339dee6f-1d8f-482c-8465-a87d2650af5e
ca0b4b5d-b55f-4712-82c4-c953584c28f1	009e3647-84a5-42be-b744-db99e853d213	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
47e5a796-f3c9-459b-b7f7-1d208f0cde20	009e3647-84a5-42be-b744-db99e853d213	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
56b93d1d-2f78-4911-9509-f8ccc7ff13f1	009e3647-84a5-42be-b744-db99e853d213	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
acbb2abe-5af3-4833-a20c-f02aa789b7bd	009e3647-84a5-42be-b744-db99e853d213	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
321c091d-f3ff-4b6d-918b-34c223f626ae	009e3647-84a5-42be-b744-db99e853d213	17	3	2.917	339dee6f-1d8f-482c-8465-a87d2650af5e
9bf1fe92-64e0-4990-a849-a2eaa402a80b	009e3647-84a5-42be-b744-db99e853d213	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
adb7dec7-8e11-4a08-a827-e698f935f28b	009e3647-84a5-42be-b744-db99e853d213	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8a66f5af-1d9c-471a-9626-0d5e8c049359	009e3647-84a5-42be-b744-db99e853d213	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5ef88b71-97ae-48dc-9e56-ba9e2436eee8	009e3647-84a5-42be-b744-db99e853d213	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ccde4c4d-0c32-473f-9187-d69155d59093	009e3647-84a5-42be-b744-db99e853d213	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6a7502c-9f1f-4c86-bb53-775671487d9e	009e3647-84a5-42be-b744-db99e853d213	18	4	0.389	339dee6f-1d8f-482c-8465-a87d2650af5e
a6fb8139-677d-4cc3-a0a7-c971dbef2e48	009e3647-84a5-42be-b744-db99e853d213	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a195bd51-0ca3-464b-8430-728521892c0d	c6643acf-9962-4fac-8d19-726aa818bbe1	1	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
da007d95-fdbc-40fa-9767-5b3333de103d	c6643acf-9962-4fac-8d19-726aa818bbe1	1	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5b537bb9-1ca6-4cec-af6f-c7a0aaf254df	c6643acf-9962-4fac-8d19-726aa818bbe1	1	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1c5db9c3-bd47-404e-a959-e490d672bdf1	c6643acf-9962-4fac-8d19-726aa818bbe1	1	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
924be0a4-96de-42aa-9fd6-a7366f6c12da	c6643acf-9962-4fac-8d19-726aa818bbe1	1	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
127af5ae-1212-4009-a069-dc6aac5b07e7	c6643acf-9962-4fac-8d19-726aa818bbe1	2	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
00c48494-ddb5-4d66-8720-3c13b0f6ea9b	c6643acf-9962-4fac-8d19-726aa818bbe1	2	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
7103b2a7-4aef-4d46-b031-7c395039b5cd	c6643acf-9962-4fac-8d19-726aa818bbe1	2	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3f429b3a-6527-4827-abe5-49b85f901496	c6643acf-9962-4fac-8d19-726aa818bbe1	2	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
fc00f8fb-0f37-4ee6-9c7a-1a8b317d6de6	c6643acf-9962-4fac-8d19-726aa818bbe1	2	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
f76e23dd-dd19-45a0-b662-0ee310685c65	c6643acf-9962-4fac-8d19-726aa818bbe1	3	1	0.273	339dee6f-1d8f-482c-8465-a87d2650af5e
668574d0-d324-45e0-9799-6d2f3f641c73	c6643acf-9962-4fac-8d19-726aa818bbe1	3	2	0.327	339dee6f-1d8f-482c-8465-a87d2650af5e
aa0217b9-a797-402e-9d4d-85a5186c49ff	c6643acf-9962-4fac-8d19-726aa818bbe1	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
45a4edd5-20a7-447b-8a2d-fce7b64cad9d	c6643acf-9962-4fac-8d19-726aa818bbe1	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
310fcbf0-45f5-434f-ab75-276947ad480b	c6643acf-9962-4fac-8d19-726aa818bbe1	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
358d91fe-eb48-453b-9585-c203cf39d0d1	c6643acf-9962-4fac-8d19-726aa818bbe1	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f6db1292-dc72-4eed-876d-c7296b6517db	c6643acf-9962-4fac-8d19-726aa818bbe1	4	2	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
60c9de01-1a7f-4299-8e54-bd3688a6a7be	c6643acf-9962-4fac-8d19-726aa818bbe1	4	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
23c6abda-637a-4860-842d-45abb84d2448	c6643acf-9962-4fac-8d19-726aa818bbe1	4	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9a0a5f1b-0b11-4a94-9728-767c3e69ea83	c6643acf-9962-4fac-8d19-726aa818bbe1	4	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
73e3d66d-1f5b-422b-8e3b-124ef37005a0	c6643acf-9962-4fac-8d19-726aa818bbe1	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1406f7dd-caf1-45f7-9a39-7fe432202bca	c6643acf-9962-4fac-8d19-726aa818bbe1	5	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3659d96e-f727-49f2-948b-657a11bb4275	c6643acf-9962-4fac-8d19-726aa818bbe1	5	3	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4398d55d-f923-4e7f-a129-596eb85ec0db	c6643acf-9962-4fac-8d19-726aa818bbe1	5	4	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3f3c430f-cb1d-496d-b7a8-ee8917b48b69	c6643acf-9962-4fac-8d19-726aa818bbe1	5	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
3c541ba4-7753-4c76-8236-51f19bad2694	c6643acf-9962-4fac-8d19-726aa818bbe1	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
846de615-4755-4422-bcf3-619524788c97	c6643acf-9962-4fac-8d19-726aa818bbe1	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
960f0467-6628-4c46-8eab-43d51417e368	c6643acf-9962-4fac-8d19-726aa818bbe1	6	3	1.773	339dee6f-1d8f-482c-8465-a87d2650af5e
270ae8e6-1381-4715-8eb6-792247902abc	c6643acf-9962-4fac-8d19-726aa818bbe1	6	4	3.274	339dee6f-1d8f-482c-8465-a87d2650af5e
9aefce2e-d586-4f9d-924d-56f78561bea5	c6643acf-9962-4fac-8d19-726aa818bbe1	6	5	0.273	339dee6f-1d8f-482c-8465-a87d2650af5e
1234e9c5-4ef4-4fec-ae14-fe60fb7c1cdf	c6643acf-9962-4fac-8d19-726aa818bbe1	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5b689168-74f7-45e3-bc6b-b94fbe152f1b	c6643acf-9962-4fac-8d19-726aa818bbe1	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f18f5f7b-c2b4-4a42-89c9-41c005eba2b6	c6643acf-9962-4fac-8d19-726aa818bbe1	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9361e683-26c2-40ab-872e-60513fa71b46	c6643acf-9962-4fac-8d19-726aa818bbe1	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b3b0c0ee-7d2d-4be3-91b8-772d618b915e	c6643acf-9962-4fac-8d19-726aa818bbe1	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ac436a0c-5517-473e-acfa-f9a46deafa20	c6643acf-9962-4fac-8d19-726aa818bbe1	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1e230746-7979-4487-9d53-56cd9f2e1da9	c6643acf-9962-4fac-8d19-726aa818bbe1	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8e953e1c-7cc1-47e2-af2f-c56e30382f0d	c6643acf-9962-4fac-8d19-726aa818bbe1	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
01bb2c19-6376-48cf-a7a8-4b6281343a17	c6643acf-9962-4fac-8d19-726aa818bbe1	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a4d8e09d-32a0-41ba-9f0e-2ca2e47a9c93	c6643acf-9962-4fac-8d19-726aa818bbe1	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1226a242-9384-46bc-95a2-6b1b529c299d	c6643acf-9962-4fac-8d19-726aa818bbe1	9	1	0.818	339dee6f-1d8f-482c-8465-a87d2650af5e
326f979f-8760-43fd-b992-f80335d01b5f	c6643acf-9962-4fac-8d19-726aa818bbe1	9	2	1.364	339dee6f-1d8f-482c-8465-a87d2650af5e
c82f1590-86b4-45d4-971e-06e4acfd1f96	c6643acf-9962-4fac-8d19-726aa818bbe1	9	3	2.728	339dee6f-1d8f-482c-8465-a87d2650af5e
0c870ed2-b09a-491f-8887-2a36a1472780	c6643acf-9962-4fac-8d19-726aa818bbe1	9	4	1.091	339dee6f-1d8f-482c-8465-a87d2650af5e
91cea19c-fdf9-4530-8bd8-b708dc0d546c	c6643acf-9962-4fac-8d19-726aa818bbe1	9	5	0.546	339dee6f-1d8f-482c-8465-a87d2650af5e
ac884964-05df-4b00-a219-7318d915d6a6	c6643acf-9962-4fac-8d19-726aa818bbe1	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1630ab63-1eb4-439e-9581-f30d23e94225	c6643acf-9962-4fac-8d19-726aa818bbe1	10	2	0.546	339dee6f-1d8f-482c-8465-a87d2650af5e
abca2374-0d7d-422b-a9b6-fcead1c3be4a	c6643acf-9962-4fac-8d19-726aa818bbe1	10	3	1.091	339dee6f-1d8f-482c-8465-a87d2650af5e
78140f05-7e7e-459a-bbe5-6213fc3f807b	c6643acf-9962-4fac-8d19-726aa818bbe1	10	4	1.091	339dee6f-1d8f-482c-8465-a87d2650af5e
3a37a272-3bd2-4931-96a5-95a5ac0481a5	c6643acf-9962-4fac-8d19-726aa818bbe1	10	5	0.273	339dee6f-1d8f-482c-8465-a87d2650af5e
df7f8a5a-0c10-4e02-b829-48731e2d3656	c6643acf-9962-4fac-8d19-726aa818bbe1	11	1	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
73055c7f-69c4-4345-896a-6cbb362c5a82	c6643acf-9962-4fac-8d19-726aa818bbe1	11	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
8b158ac7-fa1a-471e-b613-9a7f7b6b6deb	c6643acf-9962-4fac-8d19-726aa818bbe1	11	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7fa050ce-bbd1-4eff-8992-c4345bd19294	c6643acf-9962-4fac-8d19-726aa818bbe1	11	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0ef62571-b657-45e3-ac08-2600bf78bc1e	c6643acf-9962-4fac-8d19-726aa818bbe1	11	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
9eda5eb5-ad05-49d9-a893-2f002b7a9287	c6643acf-9962-4fac-8d19-726aa818bbe1	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
021dce3e-6336-49bb-8aff-9b878c1f50d0	c6643acf-9962-4fac-8d19-726aa818bbe1	12	2	0.546	339dee6f-1d8f-482c-8465-a87d2650af5e
d01f253e-b032-4acb-a396-30e978da42ee	c6643acf-9962-4fac-8d19-726aa818bbe1	12	3	2.182	339dee6f-1d8f-482c-8465-a87d2650af5e
04a1078a-fe64-45a7-886d-ed7f58ae47d1	c6643acf-9962-4fac-8d19-726aa818bbe1	12	4	2.182	339dee6f-1d8f-482c-8465-a87d2650af5e
c508c00c-6a37-4948-9d0c-a0de4cbd03a3	c6643acf-9962-4fac-8d19-726aa818bbe1	12	5	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
936ed515-46b0-402a-ac48-78c02457f16e	c6643acf-9962-4fac-8d19-726aa818bbe1	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54e6953f-a523-4e41-b88a-55de0b1b6aeb	c6643acf-9962-4fac-8d19-726aa818bbe1	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
50637656-7f6d-4caa-b7ca-f9096932c450	c6643acf-9962-4fac-8d19-726aa818bbe1	13	3	1.637	339dee6f-1d8f-482c-8465-a87d2650af5e
55b28bcd-7c85-4323-aa20-45db3a8e7531	c6643acf-9962-4fac-8d19-726aa818bbe1	13	4	1.964	339dee6f-1d8f-482c-8465-a87d2650af5e
9b15ef01-be33-4c60-90ca-2376154ad0ae	c6643acf-9962-4fac-8d19-726aa818bbe1	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e183be2a-5871-4187-a964-72edd2349c54	c6643acf-9962-4fac-8d19-726aa818bbe1	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b71867f8-5921-4881-80cf-98dc11f52ed6	c6643acf-9962-4fac-8d19-726aa818bbe1	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d4adaffd-7781-44e9-a918-37bbe6a19af2	c6643acf-9962-4fac-8d19-726aa818bbe1	14	3	0.205	339dee6f-1d8f-482c-8465-a87d2650af5e
b5e8c962-ebc1-4121-87c1-56fe82aecfed	c6643acf-9962-4fac-8d19-726aa818bbe1	14	4	0.205	339dee6f-1d8f-482c-8465-a87d2650af5e
d367da5f-0ff0-42fb-add8-39567be48722	c6643acf-9962-4fac-8d19-726aa818bbe1	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9c5527bb-19a0-4197-b2b5-34ecb80ae809	c6643acf-9962-4fac-8d19-726aa818bbe1	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ec30f93e-4ace-46a9-ba59-f97e173094e7	c6643acf-9962-4fac-8d19-726aa818bbe1	15	2	0.546	339dee6f-1d8f-482c-8465-a87d2650af5e
7471e86e-a925-41b0-8e2f-94979d88fb8f	c6643acf-9962-4fac-8d19-726aa818bbe1	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
147a322e-b417-4e3c-9e08-045fc971ef4c	c6643acf-9962-4fac-8d19-726aa818bbe1	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9428733d-f5d2-438e-b080-c091cf7c16ec	c6643acf-9962-4fac-8d19-726aa818bbe1	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e5653bb2-f841-4644-b27b-c518b9fa5709	c6643acf-9962-4fac-8d19-726aa818bbe1	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bbb58fff-7ce9-44ed-959c-bf36151039b1	c6643acf-9962-4fac-8d19-726aa818bbe1	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e08afa4b-2599-4c50-8f81-b00d177e016a	c6643acf-9962-4fac-8d19-726aa818bbe1	16	3	0.327	339dee6f-1d8f-482c-8465-a87d2650af5e
c7570e94-d8df-4141-b87d-3270b777c2ac	c6643acf-9962-4fac-8d19-726aa818bbe1	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5bb26753-566b-4f16-9313-0cd0c3c814aa	c6643acf-9962-4fac-8d19-726aa818bbe1	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6f0ade6d-5b32-426d-8bba-3b7967379d32	c6643acf-9962-4fac-8d19-726aa818bbe1	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bb360d0e-4330-43e1-8911-0f6ad54c4073	c6643acf-9962-4fac-8d19-726aa818bbe1	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
52fbec94-b2ac-4e69-abb2-30031809977c	c6643acf-9962-4fac-8d19-726aa818bbe1	17	3	0.409	339dee6f-1d8f-482c-8465-a87d2650af5e
de2c60ce-1925-4346-9414-da5510535947	c6643acf-9962-4fac-8d19-726aa818bbe1	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
62aa63d2-bc31-4c0d-b510-c4a56f7636c5	c6643acf-9962-4fac-8d19-726aa818bbe1	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a81831cb-05e2-40b6-8da7-1f4dcbfbbfc8	c6643acf-9962-4fac-8d19-726aa818bbe1	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fdb93b14-7f57-489c-8fdb-a9cfc14470a5	c6643acf-9962-4fac-8d19-726aa818bbe1	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dbee1f62-ad43-4aab-a060-f8ef2c6bbb94	c6643acf-9962-4fac-8d19-726aa818bbe1	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2043385a-f92b-4f89-90f5-aa56a61eaa7f	c6643acf-9962-4fac-8d19-726aa818bbe1	18	4	0.409	339dee6f-1d8f-482c-8465-a87d2650af5e
e53c653d-9ba3-4db1-8b2f-e2954e67fcf4	c6643acf-9962-4fac-8d19-726aa818bbe1	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5ff38da9-e35c-4419-ad64-d5bdc54dab07	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	1	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
bbc39bfc-784f-44d8-8917-011e0f05f5a3	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	2	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
a22c8449-f2c2-4c53-b24c-4c108b1baa97	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	3	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
0d64f140-102f-4755-97e0-7408e02bc250	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	4	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
f0e7ea02-fcfe-44e3-b14e-dc1cbf49eb41	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	5	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
1856c0e0-e69d-4d51-b094-5435151c0307	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	1	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
af33c42f-f9c9-4e03-bab9-f3a3c343d007	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	2	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
bb4e5332-abd0-489e-9cfd-d4f5ee0d5d5c	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	3	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
4aa13e8b-7bbb-4522-8895-5a2125fbe280	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	4	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
cb972243-797b-490f-8b2a-ce0b180b63d3	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	5	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
c38e660e-00fa-4870-bb0e-b21a59d851f0	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	3	1	0.096	339dee6f-1d8f-482c-8465-a87d2650af5e
2869e636-7dd7-487e-85b6-3f1042ef57e5	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	3	2	0.115	339dee6f-1d8f-482c-8465-a87d2650af5e
e4608cfb-0163-4beb-ba7f-b874b5a814f7	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	3	3	0.115	339dee6f-1d8f-482c-8465-a87d2650af5e
af15f81e-a71e-49d9-bc76-4ecf21997553	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74bdcf2e-053f-4ca7-8ab9-227967bf6a55	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
085a0554-8ba5-4e47-8f56-283ba2308e15	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
277dc037-e00e-4fba-b16c-7ae0c97c7008	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	4	2	0.291	339dee6f-1d8f-482c-8465-a87d2650af5e
6c73db21-d21b-4857-80cc-b3fc129ae1ef	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	4	3	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
967a0feb-7d38-4270-9836-b726060ea761	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	4	4	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
d201176b-8efc-428a-b9a3-70dd47dbe2b9	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	4	5	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
6aaef0ab-efa8-4cf9-b5f1-0af645435ce2	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
814e9de9-67e4-4d45-8fe2-acd7edf07cf3	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	5	2	0.872	339dee6f-1d8f-482c-8465-a87d2650af5e
bfdec018-c9dc-4d93-8419-3a5412cb7929	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	5	3	1.744	339dee6f-1d8f-482c-8465-a87d2650af5e
0470308c-3cf8-4f43-8bea-256153d4a5ce	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	5	4	1.744	339dee6f-1d8f-482c-8465-a87d2650af5e
c833d946-b832-4e67-ac5f-7bd426c70ae6	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	5	5	0.436	339dee6f-1d8f-482c-8465-a87d2650af5e
f17b0744-79c4-4987-ab4f-52a906532a7d	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
589e92ac-2437-4590-ac75-82c1bde12d60	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a8d3100e-8eac-4d6a-a57e-d28c219ac591	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	6	3	1.342	339dee6f-1d8f-482c-8465-a87d2650af5e
c26c3d76-1580-4f41-b60c-bfa3d28136a7	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	6	4	2.071	339dee6f-1d8f-482c-8465-a87d2650af5e
9c451c59-0510-46fb-8033-6e0028b3c135	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	6	5	0.383	339dee6f-1d8f-482c-8465-a87d2650af5e
6a0c850c-2e8c-4be2-835f-6c995ec9dc64	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	7	1	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
5f62b7a5-d2bf-4b1f-9d14-64027a0dc126	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	7	2	1.150	339dee6f-1d8f-482c-8465-a87d2650af5e
4ba396b2-ea3e-4e1b-85c0-a04bf14437bc	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	7	3	1.150	339dee6f-1d8f-482c-8465-a87d2650af5e
a1626ca1-3d8e-4495-91eb-e43e777b1149	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	7	4	0.575	339dee6f-1d8f-482c-8465-a87d2650af5e
939ae378-93e1-4f9e-a15b-558d04f55428	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	7	5	0.383	339dee6f-1d8f-482c-8465-a87d2650af5e
6b37f5b1-1691-4de4-a817-7efed1f5ddaa	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	8	1	0.537	339dee6f-1d8f-482c-8465-a87d2650af5e
1182d2e9-ba65-4848-b266-752e0a6b9713	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	8	2	1.150	339dee6f-1d8f-482c-8465-a87d2650af5e
400837de-1a94-4e85-b25c-90f30c3268a6	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	8	3	1.150	339dee6f-1d8f-482c-8465-a87d2650af5e
37ddb302-57e5-4076-b628-9a210af97d57	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	8	4	0.575	339dee6f-1d8f-482c-8465-a87d2650af5e
867eae33-d09e-44d7-9516-d24936074a26	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	8	5	0.383	339dee6f-1d8f-482c-8465-a87d2650af5e
9289900d-a929-4294-8782-9e224775b246	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a9ecbf3-c8ff-4d7a-8d12-d19b71a15c87	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1928c09f-6e77-4676-8e98-7f15d40ab655	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
061b1d66-6f74-45c6-865d-329b838a7760	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d4b827b4-8fd2-4647-a49a-de9736cb8ee4	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c4f24f8f-6407-4158-a696-82fbd5228cf3	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6dffc79e-3587-4a16-989f-cbe7db03fb00	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	10	2	0.192	339dee6f-1d8f-482c-8465-a87d2650af5e
593233b1-49b2-45a4-8e35-e359257a43de	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	10	3	0.192	339dee6f-1d8f-482c-8465-a87d2650af5e
9d55abcf-03b6-4d27-8c69-08284dd009b8	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	10	4	0.192	339dee6f-1d8f-482c-8465-a87d2650af5e
2085505c-0165-4289-8a77-4088d2ce8a21	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	10	5	0.192	339dee6f-1d8f-482c-8465-a87d2650af5e
5dda6a21-4001-47df-8c8f-3fe974f8a4ea	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	11	1	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
46b9d0bd-8acc-4526-9a9b-e6a674e8238d	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	11	2	0.233	339dee6f-1d8f-482c-8465-a87d2650af5e
35914663-83b2-4dcb-aa9a-ff9b351f7c50	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	11	3	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
9763dfb7-5871-4250-be8f-e2cc3e81cb81	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	11	4	0.581	339dee6f-1d8f-482c-8465-a87d2650af5e
d491e8a6-6f66-474a-9eeb-c97468cf8f17	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	11	5	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
72316ec7-d631-4d7b-9904-a06e2d4058c9	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b1d90154-074d-41d0-ad99-39fa63b5673a	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	12	2	0.240	339dee6f-1d8f-482c-8465-a87d2650af5e
3cfe3f91-4b78-49a1-b398-b324f8b211bb	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	12	3	1.917	339dee6f-1d8f-482c-8465-a87d2650af5e
bd53d759-bd7b-4859-a682-3b7252f8eb6e	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	12	4	2.397	339dee6f-1d8f-482c-8465-a87d2650af5e
a81078cc-b67a-4f74-b0da-059cb1a56256	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	12	5	0.120	339dee6f-1d8f-482c-8465-a87d2650af5e
c897a04e-c978-40db-986f-c45af517b8b3	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9c5c4a1f-178f-4ab9-8e99-4618a058b9e3	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ffd4740e-1c27-4a54-9e58-d0cd16783e15	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	13	3	0.863	339dee6f-1d8f-482c-8465-a87d2650af5e
b959219c-0e77-4e77-a851-e80b64a0c589	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	13	4	0.863	339dee6f-1d8f-482c-8465-a87d2650af5e
fc20da00-dfc0-4d94-b863-de294e3e2a04	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9d49894c-52b5-46f3-9209-a15e1e45ab98	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ff5d07eb-acfa-458e-a2b4-257522c3dcb9	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9da16b72-c863-41ad-bb38-a0eba8cdad20	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	14	3	0.072	339dee6f-1d8f-482c-8465-a87d2650af5e
1dc73b6c-5cbb-4583-8256-042425258936	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	14	4	0.072	339dee6f-1d8f-482c-8465-a87d2650af5e
76026423-bcd8-45b2-837c-2ae9e9f840fe	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d890b05a-caa3-4637-9e83-4c09c514b7bb	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c7c05179-d826-43ab-875b-2c8a21b30aae	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	15	2	0.144	339dee6f-1d8f-482c-8465-a87d2650af5e
f9331734-6d1f-4847-a9e2-e0a30e9057db	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdb10974-a19e-42ad-a685-079a45db47b6	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
84826304-fe0c-4593-bbd9-e0a7455a87d2	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
448a6805-4c49-4e5c-8f3a-022a219d9cca	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8963d157-31e1-48ec-bebe-576207eba9ed	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9b8b282e-f6dd-44dc-83d2-190676f49e96	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	16	3	0.144	339dee6f-1d8f-482c-8465-a87d2650af5e
f2172f58-f68e-496b-aa73-192146ca712c	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d2691e3c-2f13-49f8-8fe2-9ccbabcdec4b	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a219c3be-5e04-423a-8808-a91c1c68e334	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3e40c8ea-4727-45f6-8884-13c323d733a9	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
65498806-0b40-4069-bdab-a1205db482d6	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	17	3	0.192	339dee6f-1d8f-482c-8465-a87d2650af5e
d63e914e-c3a7-4ade-88ff-413872c86bd7	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a270aa88-4866-4190-9a5c-f00618243c54	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
56def5bd-b784-43aa-8c7e-225076544539	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
992aa2cc-e6fb-4a8c-89d9-7924cfb6b1cd	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a65c529-d704-43b6-a9f1-5278416be773	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
61d92e38-c38b-4de2-b0a9-0b32e6f090ee	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	18	4	0.144	339dee6f-1d8f-482c-8465-a87d2650af5e
e2d07ea3-5e1d-42a9-af45-a4a3910be19f	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a8316775-5ce6-4dbd-bef7-c06cf020d812	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	1	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
ce80636c-f2cb-4157-94b6-73da3cb4a233	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	2	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
da9e13ac-08f7-4db4-902b-05c17e331475	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	3	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
e355c4a3-2cab-4432-95a9-7691c86c2fc8	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	4	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
72e8800b-f45a-42eb-b9ad-b16e9b70813d	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	5	0.020	339dee6f-1d8f-482c-8465-a87d2650af5e
a3ea7500-107d-45ef-bccb-712c53725a1b	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	1	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
e6c5c90f-56e0-4bb8-9790-6565e1254c18	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	2	0.060	339dee6f-1d8f-482c-8465-a87d2650af5e
91ce0009-3a60-492c-9c59-1adcfda59ef3	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	3	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
c52ca3d0-4b55-4554-90d0-a3726a0b9111	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	4	0.060	339dee6f-1d8f-482c-8465-a87d2650af5e
c0be84bb-7f91-44e3-9bf1-76e7b81e9a5b	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	5	0.020	339dee6f-1d8f-482c-8465-a87d2650af5e
63c65a4c-1367-4a21-87ff-3f07d8bc78a6	4861aa99-4f1c-4d89-adc0-344c5e20a882	3	1	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
a2599c9c-ef42-4896-b7b6-5b623d4c7963	4861aa99-4f1c-4d89-adc0-344c5e20a882	3	2	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
a0847224-4d08-4079-bad8-827a0a6440dd	4861aa99-4f1c-4d89-adc0-344c5e20a882	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a4be2d59-1217-45b1-88fb-220548692ce7	4861aa99-4f1c-4d89-adc0-344c5e20a882	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
be18ebae-f4b7-417b-831b-a99fccc29e9b	4861aa99-4f1c-4d89-adc0-344c5e20a882	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f5b58a3b-57b2-4ac1-8c46-0f9427c139ff	4861aa99-4f1c-4d89-adc0-344c5e20a882	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dcd1a1ba-d0d1-427f-8e7b-1cc91efe65cd	4861aa99-4f1c-4d89-adc0-344c5e20a882	4	2	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
72f2f411-3414-46b4-b358-b11e83301803	4861aa99-4f1c-4d89-adc0-344c5e20a882	4	3	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
6f743007-3cf6-4a31-a978-d38691f61497	4861aa99-4f1c-4d89-adc0-344c5e20a882	4	4	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
2e2f79d9-5bf2-4421-9229-5bcd7774d9c8	4861aa99-4f1c-4d89-adc0-344c5e20a882	4	5	0.020	339dee6f-1d8f-482c-8465-a87d2650af5e
5101ab60-408c-4333-bfef-5d3cd68aba75	4861aa99-4f1c-4d89-adc0-344c5e20a882	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9c9d7b7b-f26d-4932-a870-b8a72b0af1c0	4861aa99-4f1c-4d89-adc0-344c5e20a882	5	2	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
470f1b44-27a6-4417-aa51-b5b2b9e874ff	4861aa99-4f1c-4d89-adc0-344c5e20a882	5	3	0.161	339dee6f-1d8f-482c-8465-a87d2650af5e
ed4a8a56-c3bf-44a5-aad0-54d3b5426d44	4861aa99-4f1c-4d89-adc0-344c5e20a882	5	4	0.161	339dee6f-1d8f-482c-8465-a87d2650af5e
ae078cac-4acc-4c02-9f95-b36f57e6f470	4861aa99-4f1c-4d89-adc0-344c5e20a882	5	5	0.020	339dee6f-1d8f-482c-8465-a87d2650af5e
52dab39c-33f5-4b54-8d95-5b0278a6f01c	4861aa99-4f1c-4d89-adc0-344c5e20a882	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b633c326-a993-448d-ac14-795327e29192	4861aa99-4f1c-4d89-adc0-344c5e20a882	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c5547234-081b-48cc-86ef-88eecd7bcaff	4861aa99-4f1c-4d89-adc0-344c5e20a882	6	3	0.219	339dee6f-1d8f-482c-8465-a87d2650af5e
3efc083a-f325-40ac-88ee-3df185cc0e8e	4861aa99-4f1c-4d89-adc0-344c5e20a882	6	4	0.405	339dee6f-1d8f-482c-8465-a87d2650af5e
e95c36bd-a192-49e0-94d1-d16d755dedf1	4861aa99-4f1c-4d89-adc0-344c5e20a882	6	5	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
e5297cc4-4640-4e0e-9a80-8227404f400b	4861aa99-4f1c-4d89-adc0-344c5e20a882	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
17a36366-3b73-4b53-b00a-d1b55b71480f	4861aa99-4f1c-4d89-adc0-344c5e20a882	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fd322108-e9bf-4427-b08f-8957b8e6a796	4861aa99-4f1c-4d89-adc0-344c5e20a882	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bed860e9-350b-4a69-be11-28104a9f8674	4861aa99-4f1c-4d89-adc0-344c5e20a882	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a2a2534-f018-4ced-b030-7b7df5787dda	4861aa99-4f1c-4d89-adc0-344c5e20a882	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f7d062a0-a7c2-4b63-acb7-800b9afd9757	4861aa99-4f1c-4d89-adc0-344c5e20a882	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
db0adab4-a26c-484a-8f1c-29991a14949d	4861aa99-4f1c-4d89-adc0-344c5e20a882	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f05fb14e-16f8-4434-be68-0b325642b49d	4861aa99-4f1c-4d89-adc0-344c5e20a882	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
78cb8972-221a-41cf-9118-08351bd1b418	4861aa99-4f1c-4d89-adc0-344c5e20a882	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
16da3098-aa7f-48b4-bfd1-b136d65e456b	4861aa99-4f1c-4d89-adc0-344c5e20a882	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ff72320d-d4a9-4da1-b5d5-63b9a26f3c12	4861aa99-4f1c-4d89-adc0-344c5e20a882	9	1	0.101	339dee6f-1d8f-482c-8465-a87d2650af5e
4b8c1fd9-c208-49b8-8374-dac3c35d0ba6	4861aa99-4f1c-4d89-adc0-344c5e20a882	9	2	0.169	339dee6f-1d8f-482c-8465-a87d2650af5e
e97ed6d7-472a-4625-8d18-0d6e5d2b059e	4861aa99-4f1c-4d89-adc0-344c5e20a882	9	3	0.337	339dee6f-1d8f-482c-8465-a87d2650af5e
d7c89137-bdd8-4b30-b1d1-b06b5658100d	4861aa99-4f1c-4d89-adc0-344c5e20a882	9	4	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
4f95efc8-43b8-4bf3-9f77-2ed6cb7261c7	4861aa99-4f1c-4d89-adc0-344c5e20a882	9	5	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
5c482791-02e1-4aa6-9859-1e39b2de4aa6	4861aa99-4f1c-4d89-adc0-344c5e20a882	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d0b1865c-2f78-4d52-83e9-6ee89cf2b050	4861aa99-4f1c-4d89-adc0-344c5e20a882	10	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
995a8a72-e76b-49ac-b239-acf4943daaf7	4861aa99-4f1c-4d89-adc0-344c5e20a882	10	3	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
cf24fb51-f4cb-4764-823e-7ddce31fbda3	4861aa99-4f1c-4d89-adc0-344c5e20a882	10	4	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
cffb2bcc-ed86-4f79-ab51-632c602e9566	4861aa99-4f1c-4d89-adc0-344c5e20a882	10	5	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
461fb1d5-399d-4d38-93bc-1607b4769aff	4861aa99-4f1c-4d89-adc0-344c5e20a882	11	1	0.020	339dee6f-1d8f-482c-8465-a87d2650af5e
9986b300-6838-4583-b356-c81daf9c1e28	4861aa99-4f1c-4d89-adc0-344c5e20a882	11	2	0.032	339dee6f-1d8f-482c-8465-a87d2650af5e
13a2d411-6c2c-4830-b574-00921e3862dc	4861aa99-4f1c-4d89-adc0-344c5e20a882	11	3	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
c6f1af61-95b5-40fb-aae1-113cc1b838fb	4861aa99-4f1c-4d89-adc0-344c5e20a882	11	4	0.080	339dee6f-1d8f-482c-8465-a87d2650af5e
e2d6c720-5b7c-41e6-9a6d-289d3ff81ab8	4861aa99-4f1c-4d89-adc0-344c5e20a882	11	5	0.020	339dee6f-1d8f-482c-8465-a87d2650af5e
0786c6b4-51dd-4163-b102-b562698d85be	4861aa99-4f1c-4d89-adc0-344c5e20a882	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c8c087d5-899b-479a-a580-8b03bc8c0198	4861aa99-4f1c-4d89-adc0-344c5e20a882	12	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
a28be9d4-1078-4bab-a0fb-faa52562fda2	4861aa99-4f1c-4d89-adc0-344c5e20a882	12	3	0.270	339dee6f-1d8f-482c-8465-a87d2650af5e
56d6bdc0-181d-4b81-ae9e-f653833ef145	4861aa99-4f1c-4d89-adc0-344c5e20a882	12	4	0.270	339dee6f-1d8f-482c-8465-a87d2650af5e
79207d23-bcfb-41aa-a655-eb9c058eef3b	4861aa99-4f1c-4d89-adc0-344c5e20a882	12	5	0.042	339dee6f-1d8f-482c-8465-a87d2650af5e
26ab1ece-a394-489e-9a80-98c121f0e4ad	4861aa99-4f1c-4d89-adc0-344c5e20a882	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
95d4dad7-07ac-4e22-a927-c36a25c37bfc	4861aa99-4f1c-4d89-adc0-344c5e20a882	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
624c2722-3498-4c3f-b61d-eaa98dee0d72	4861aa99-4f1c-4d89-adc0-344c5e20a882	13	3	0.202	339dee6f-1d8f-482c-8465-a87d2650af5e
121597f4-18cf-49f9-ba1f-d98ff708bbf3	4861aa99-4f1c-4d89-adc0-344c5e20a882	13	4	0.243	339dee6f-1d8f-482c-8465-a87d2650af5e
87020efa-702f-4e30-95cf-103072891fd2	4861aa99-4f1c-4d89-adc0-344c5e20a882	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
75f930d6-a01e-4268-878e-e3a431bd2f50	4861aa99-4f1c-4d89-adc0-344c5e20a882	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ad63a07a-1e8a-48a9-af25-1e041f04a3fa	4861aa99-4f1c-4d89-adc0-344c5e20a882	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dbf334b6-b964-4b10-a34f-f1184ab14370	4861aa99-4f1c-4d89-adc0-344c5e20a882	14	3	0.025	339dee6f-1d8f-482c-8465-a87d2650af5e
8764f1e2-3804-417d-a197-489ab7ebeb2e	4861aa99-4f1c-4d89-adc0-344c5e20a882	14	4	0.025	339dee6f-1d8f-482c-8465-a87d2650af5e
6218f356-432c-4122-b8ce-c70c06396a3b	4861aa99-4f1c-4d89-adc0-344c5e20a882	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d75097b5-75d5-4dc3-bb8a-5fc3835a3dc7	4861aa99-4f1c-4d89-adc0-344c5e20a882	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8c2e9706-0bc8-4f25-88c5-d807065cb0ed	4861aa99-4f1c-4d89-adc0-344c5e20a882	15	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
1cceec53-d855-42b5-b8b2-e7d00e797443	4861aa99-4f1c-4d89-adc0-344c5e20a882	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c6c7479e-668f-44f1-877a-9259460e05e7	4861aa99-4f1c-4d89-adc0-344c5e20a882	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
be47c078-3381-49d3-864d-19d5c69c25bd	4861aa99-4f1c-4d89-adc0-344c5e20a882	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
95fe9e89-7cb1-4736-b08a-3cc74f158fa8	4861aa99-4f1c-4d89-adc0-344c5e20a882	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dc28ee26-4f4b-42e0-ba04-db38497ad0b4	4861aa99-4f1c-4d89-adc0-344c5e20a882	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b5595691-fc2d-4352-87d7-8314e278914d	4861aa99-4f1c-4d89-adc0-344c5e20a882	16	3	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
071fdcf1-948b-4268-973a-226288576ca9	4861aa99-4f1c-4d89-adc0-344c5e20a882	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4e8319d3-48d9-4265-96e7-a9795003d875	4861aa99-4f1c-4d89-adc0-344c5e20a882	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
90d17f05-be38-4002-8222-9460967e6f3d	4861aa99-4f1c-4d89-adc0-344c5e20a882	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
31120500-4b1f-42f5-b085-4b0eae809e29	4861aa99-4f1c-4d89-adc0-344c5e20a882	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cf894c66-3f90-4e29-b8a4-ecb00511a8f6	4861aa99-4f1c-4d89-adc0-344c5e20a882	17	3	0.051	339dee6f-1d8f-482c-8465-a87d2650af5e
c6e59e96-44a3-4ed4-80e8-c94096aa06b0	4861aa99-4f1c-4d89-adc0-344c5e20a882	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aad335cf-d7a7-45c9-aebb-7669788d80ee	4861aa99-4f1c-4d89-adc0-344c5e20a882	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f1b36b17-0264-4880-a775-a9eba49e4d5a	4861aa99-4f1c-4d89-adc0-344c5e20a882	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
852b3c04-db48-478e-a4a3-1e63102d5f38	4861aa99-4f1c-4d89-adc0-344c5e20a882	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3386a14d-7375-4fed-830f-2fe750eb0ead	4861aa99-4f1c-4d89-adc0-344c5e20a882	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9deb29e3-cd40-42a2-82e9-5d158d2b4764	4861aa99-4f1c-4d89-adc0-344c5e20a882	18	4	0.051	339dee6f-1d8f-482c-8465-a87d2650af5e
3a5f0e91-9552-4f9c-a5d3-9c865da57311	4861aa99-4f1c-4d89-adc0-344c5e20a882	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
72ae1873-7afd-49ed-bf2e-5dd06f52d7ec	eab754f9-ba9b-4824-8f79-e559ea109ed4	1	1	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
e0b6c064-8c1b-481d-9d4a-bbe853a9fb3c	eab754f9-ba9b-4824-8f79-e559ea109ed4	1	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
3c19f68a-29f6-4704-9d23-e4696c0f78ed	eab754f9-ba9b-4824-8f79-e559ea109ed4	1	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
2461d488-ac7a-410e-9dc9-65c29f040c22	eab754f9-ba9b-4824-8f79-e559ea109ed4	1	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
fc961607-bb31-43fe-a8e9-148eeb69375d	eab754f9-ba9b-4824-8f79-e559ea109ed4	1	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
461c2f24-2b08-4e80-82a7-3cc3993ef39e	eab754f9-ba9b-4824-8f79-e559ea109ed4	2	1	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
5ef19e71-f7a1-4e16-8d0f-879b79207d51	eab754f9-ba9b-4824-8f79-e559ea109ed4	2	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
143422bb-956d-4b8f-be31-9963d4734774	eab754f9-ba9b-4824-8f79-e559ea109ed4	2	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
caf2d24e-8a15-4595-be93-a15993aaceef	eab754f9-ba9b-4824-8f79-e559ea109ed4	2	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
f64060ee-6c8f-4bac-8bca-6e846f4f4e8d	eab754f9-ba9b-4824-8f79-e559ea109ed4	2	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
72537925-b4d9-4bbc-9a0a-bd90519449b1	eab754f9-ba9b-4824-8f79-e559ea109ed4	3	1	0.058	339dee6f-1d8f-482c-8465-a87d2650af5e
17476ed2-fc79-433e-92c7-7463e76bdd4e	eab754f9-ba9b-4824-8f79-e559ea109ed4	3	2	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
ce59fb19-8124-4921-8c28-c53d7debe470	eab754f9-ba9b-4824-8f79-e559ea109ed4	3	3	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
8a351103-2716-4bca-86f8-15c7afe232ae	eab754f9-ba9b-4824-8f79-e559ea109ed4	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aa214472-3812-441b-82a3-bc3018debdfc	eab754f9-ba9b-4824-8f79-e559ea109ed4	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b9f66c0-b853-4ef9-8b7a-f6571f8b29d8	eab754f9-ba9b-4824-8f79-e559ea109ed4	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5572d26e-ba54-48d6-8c01-d713214c396c	eab754f9-ba9b-4824-8f79-e559ea109ed4	4	2	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
ad8234d9-f02a-496b-958e-37f5c39bfa10	eab754f9-ba9b-4824-8f79-e559ea109ed4	4	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
c5ed7df6-e4d9-4414-b96a-f1f81ae047a0	eab754f9-ba9b-4824-8f79-e559ea109ed4	4	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
a0b55617-8e51-43fa-b9e0-7f696c908310	eab754f9-ba9b-4824-8f79-e559ea109ed4	4	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
96923dd9-3474-4651-b4d7-b3e25857a91d	eab754f9-ba9b-4824-8f79-e559ea109ed4	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
10311e95-ddac-4db5-b788-7c57d51dd3e1	eab754f9-ba9b-4824-8f79-e559ea109ed4	5	2	0.600	339dee6f-1d8f-482c-8465-a87d2650af5e
b398ef2d-061f-4b06-a250-5495f3777b28	eab754f9-ba9b-4824-8f79-e559ea109ed4	5	3	1.200	339dee6f-1d8f-482c-8465-a87d2650af5e
dc5020e5-cde3-405d-9ef1-335a80397e35	eab754f9-ba9b-4824-8f79-e559ea109ed4	5	4	1.200	339dee6f-1d8f-482c-8465-a87d2650af5e
8f43dbf1-2a0d-409d-898d-30554553b679	eab754f9-ba9b-4824-8f79-e559ea109ed4	5	5	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
aeccda79-1374-4fba-a43f-acd9a2bf0437	eab754f9-ba9b-4824-8f79-e559ea109ed4	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b199efd2-b603-449c-a926-402ae047a94f	eab754f9-ba9b-4824-8f79-e559ea109ed4	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0bbaf899-eb45-4b0f-b8e0-8e610d2c3022	eab754f9-ba9b-4824-8f79-e559ea109ed4	6	3	0.815	339dee6f-1d8f-482c-8465-a87d2650af5e
4680f58a-5306-4275-99bc-b43c0b08159e	eab754f9-ba9b-4824-8f79-e559ea109ed4	6	4	1.257	339dee6f-1d8f-482c-8465-a87d2650af5e
d9bb952a-86c4-444d-a1b8-2a5fb4e8196c	eab754f9-ba9b-4824-8f79-e559ea109ed4	6	5	0.233	339dee6f-1d8f-482c-8465-a87d2650af5e
a95d92fa-3923-4780-887c-bc1b971561f2	eab754f9-ba9b-4824-8f79-e559ea109ed4	7	1	0.326	339dee6f-1d8f-482c-8465-a87d2650af5e
e0588e54-63f1-475c-be95-11791e2ca92f	eab754f9-ba9b-4824-8f79-e559ea109ed4	7	2	0.699	339dee6f-1d8f-482c-8465-a87d2650af5e
cce5d812-da00-44c5-81c5-ce6cc3fd9c09	eab754f9-ba9b-4824-8f79-e559ea109ed4	7	3	0.699	339dee6f-1d8f-482c-8465-a87d2650af5e
876abee2-f00b-44de-b097-ab3dbad2a74f	eab754f9-ba9b-4824-8f79-e559ea109ed4	7	4	0.349	339dee6f-1d8f-482c-8465-a87d2650af5e
ccd874ca-39d3-4bcc-8a48-3a661966381d	eab754f9-ba9b-4824-8f79-e559ea109ed4	7	5	0.233	339dee6f-1d8f-482c-8465-a87d2650af5e
0faca39b-b435-4785-9314-10a185859de6	eab754f9-ba9b-4824-8f79-e559ea109ed4	8	1	0.326	339dee6f-1d8f-482c-8465-a87d2650af5e
ec641141-5040-432e-a814-afff19600e7e	eab754f9-ba9b-4824-8f79-e559ea109ed4	8	2	0.699	339dee6f-1d8f-482c-8465-a87d2650af5e
5964a4b9-e163-4c7b-8c00-23df913e0680	eab754f9-ba9b-4824-8f79-e559ea109ed4	8	3	0.699	339dee6f-1d8f-482c-8465-a87d2650af5e
9ecaab09-30cb-48f8-99a6-37ff791aab01	eab754f9-ba9b-4824-8f79-e559ea109ed4	8	4	0.349	339dee6f-1d8f-482c-8465-a87d2650af5e
22d54717-61ee-4973-a265-8824bbf2585d	eab754f9-ba9b-4824-8f79-e559ea109ed4	8	5	0.233	339dee6f-1d8f-482c-8465-a87d2650af5e
ec8edab2-fb33-46a5-b67b-6c07ec74d39f	eab754f9-ba9b-4824-8f79-e559ea109ed4	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a416598b-e7cf-49e8-81b9-21bc031f66b6	eab754f9-ba9b-4824-8f79-e559ea109ed4	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0ec7703b-06cb-45e9-b20f-eee3f4c90f7e	eab754f9-ba9b-4824-8f79-e559ea109ed4	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6b88f84c-7901-4593-8af4-5c76f17c6e14	eab754f9-ba9b-4824-8f79-e559ea109ed4	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7d670bc1-50e3-4ead-8b8a-47bfd70b9f12	eab754f9-ba9b-4824-8f79-e559ea109ed4	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8e35a0f1-f403-46cb-a057-e754087b3206	eab754f9-ba9b-4824-8f79-e559ea109ed4	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
61f4b2e0-6680-4d12-bb35-384110761e86	eab754f9-ba9b-4824-8f79-e559ea109ed4	10	2	0.116	339dee6f-1d8f-482c-8465-a87d2650af5e
5176f593-e50b-4220-a147-18f42b9b751e	eab754f9-ba9b-4824-8f79-e559ea109ed4	10	3	0.116	339dee6f-1d8f-482c-8465-a87d2650af5e
ff69e3ab-cee3-4ee4-aa9a-2dcd4a4fe265	eab754f9-ba9b-4824-8f79-e559ea109ed4	10	4	0.116	339dee6f-1d8f-482c-8465-a87d2650af5e
7fcf16ba-3765-4681-ac9d-2766aa4930ea	eab754f9-ba9b-4824-8f79-e559ea109ed4	10	5	0.116	339dee6f-1d8f-482c-8465-a87d2650af5e
89330e8a-a699-4b6c-a40e-3746d10eb1d8	eab754f9-ba9b-4824-8f79-e559ea109ed4	11	1	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
bb611a85-0436-4262-83d5-af5d658c6c3e	eab754f9-ba9b-4824-8f79-e559ea109ed4	11	2	0.160	339dee6f-1d8f-482c-8465-a87d2650af5e
961154c3-fa1a-4abf-a0e9-6058524bacf3	eab754f9-ba9b-4824-8f79-e559ea109ed4	11	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
223b40ae-238b-4900-88bd-a590d5c82410	eab754f9-ba9b-4824-8f79-e559ea109ed4	11	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
236aa9d3-80df-42c3-bd61-f3bc6716a754	eab754f9-ba9b-4824-8f79-e559ea109ed4	11	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
0bbbb49b-3753-44fa-9d71-c3ea8e79d7bb	eab754f9-ba9b-4824-8f79-e559ea109ed4	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0a76d28c-942d-4049-9676-e8627f7be489	eab754f9-ba9b-4824-8f79-e559ea109ed4	12	2	0.146	339dee6f-1d8f-482c-8465-a87d2650af5e
7ae549a0-ea6e-4c2f-91e0-d7dc50b3558e	eab754f9-ba9b-4824-8f79-e559ea109ed4	12	3	1.164	339dee6f-1d8f-482c-8465-a87d2650af5e
de4cabf3-481e-4821-8470-4e8bc75ef7a3	eab754f9-ba9b-4824-8f79-e559ea109ed4	12	4	1.455	339dee6f-1d8f-482c-8465-a87d2650af5e
2fa65d10-827c-4778-90a7-f6e47471ca9d	eab754f9-ba9b-4824-8f79-e559ea109ed4	12	5	0.073	339dee6f-1d8f-482c-8465-a87d2650af5e
b5f16352-b998-421e-a5a4-2467e10c26f8	eab754f9-ba9b-4824-8f79-e559ea109ed4	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e1e5f806-c244-4ccc-9e9c-34c921161925	eab754f9-ba9b-4824-8f79-e559ea109ed4	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6e079b9e-4457-4546-8b3b-dd38fad14fab	eab754f9-ba9b-4824-8f79-e559ea109ed4	13	3	0.524	339dee6f-1d8f-482c-8465-a87d2650af5e
4dbfced4-893f-4e88-a179-58754e17340c	eab754f9-ba9b-4824-8f79-e559ea109ed4	13	4	0.524	339dee6f-1d8f-482c-8465-a87d2650af5e
c6636f7c-8676-49b5-87c2-f4257e7855b5	eab754f9-ba9b-4824-8f79-e559ea109ed4	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
407f16ba-365a-4f54-a695-46498bce29d7	eab754f9-ba9b-4824-8f79-e559ea109ed4	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bbf6e442-d914-439d-8588-4c36e9b205a9	eab754f9-ba9b-4824-8f79-e559ea109ed4	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
98058b9e-81e5-4032-b896-78db6893bf58	eab754f9-ba9b-4824-8f79-e559ea109ed4	14	3	0.044	339dee6f-1d8f-482c-8465-a87d2650af5e
c3486695-1b2d-4995-9959-e858891c73ad	eab754f9-ba9b-4824-8f79-e559ea109ed4	14	4	0.044	339dee6f-1d8f-482c-8465-a87d2650af5e
1791d02e-fde7-4d5f-b967-c01080a3c9f0	eab754f9-ba9b-4824-8f79-e559ea109ed4	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c1f6d952-d432-410c-98cf-a633f900cb11	eab754f9-ba9b-4824-8f79-e559ea109ed4	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c4c8cbff-550c-46a8-ac4c-54ebcd714fce	eab754f9-ba9b-4824-8f79-e559ea109ed4	15	2	0.087	339dee6f-1d8f-482c-8465-a87d2650af5e
99e1c6f5-5c8a-47a2-9dfe-8c3f3f8b5385	eab754f9-ba9b-4824-8f79-e559ea109ed4	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cc921e41-bd97-43eb-9896-73ab08e2b26d	eab754f9-ba9b-4824-8f79-e559ea109ed4	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3819ca92-7b64-4a50-81ab-08195ffde92b	eab754f9-ba9b-4824-8f79-e559ea109ed4	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1b7f1d50-bded-4ac1-96e2-eefefe605833	eab754f9-ba9b-4824-8f79-e559ea109ed4	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
035d91d5-08c0-4184-b86c-781e34e9fabc	eab754f9-ba9b-4824-8f79-e559ea109ed4	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
35f36dc5-a3f3-4581-a1bf-a9cd52648923	eab754f9-ba9b-4824-8f79-e559ea109ed4	16	3	0.087	339dee6f-1d8f-482c-8465-a87d2650af5e
46dc2b8a-6efe-44eb-a041-cdc7e9bcfd8b	eab754f9-ba9b-4824-8f79-e559ea109ed4	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
96989c3f-ef92-4784-acdf-dd6db4fa725e	eab754f9-ba9b-4824-8f79-e559ea109ed4	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1a27bab3-20dc-494b-859e-9b8b045bf6f6	eab754f9-ba9b-4824-8f79-e559ea109ed4	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a84862b-9d2e-4d22-af44-ab0cfa7b4e9b	eab754f9-ba9b-4824-8f79-e559ea109ed4	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a568d1ea-494f-4163-a810-b6c121134003	eab754f9-ba9b-4824-8f79-e559ea109ed4	17	3	0.116	339dee6f-1d8f-482c-8465-a87d2650af5e
d42f522f-d3df-4b74-96aa-54e9e4214933	eab754f9-ba9b-4824-8f79-e559ea109ed4	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bb86a57c-972a-482d-b224-eb5c61a1d908	eab754f9-ba9b-4824-8f79-e559ea109ed4	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4915cc5c-01cd-466a-81ac-5947699973da	eab754f9-ba9b-4824-8f79-e559ea109ed4	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0468aaf2-09dd-464b-8d80-07c5b4e2bf79	eab754f9-ba9b-4824-8f79-e559ea109ed4	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d9b9a502-ed2b-4774-ad5a-2aca8ada7e44	eab754f9-ba9b-4824-8f79-e559ea109ed4	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
98e777ad-bcd1-4bb1-b92d-2e17318901cf	eab754f9-ba9b-4824-8f79-e559ea109ed4	18	4	0.087	339dee6f-1d8f-482c-8465-a87d2650af5e
ec4091ee-488c-4733-bff2-cdc7b5e6d098	eab754f9-ba9b-4824-8f79-e559ea109ed4	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b565d576-35e3-48af-a963-8c9be9af9ad8	107a8b49-cfb7-49d4-a3dd-f45d256664ae	1	1	0.168	339dee6f-1d8f-482c-8465-a87d2650af5e
12a721b5-c299-4f1f-9483-d969dd22c298	107a8b49-cfb7-49d4-a3dd-f45d256664ae	1	2	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
e8454c05-5bb1-4040-a3a2-edf4d194b0c4	107a8b49-cfb7-49d4-a3dd-f45d256664ae	1	3	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
58d5973a-b846-45ad-ad15-2163809c2564	107a8b49-cfb7-49d4-a3dd-f45d256664ae	1	4	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
e8ef3e6f-fa2b-471e-bab9-8118112ed1a8	107a8b49-cfb7-49d4-a3dd-f45d256664ae	1	5	0.084	339dee6f-1d8f-482c-8465-a87d2650af5e
8ac6867b-5fa4-4149-9736-fed84d79ae2c	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	1	0.168	339dee6f-1d8f-482c-8465-a87d2650af5e
63a83a00-dd5d-4c23-aef2-e8feea5f313a	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	2	0.251	339dee6f-1d8f-482c-8465-a87d2650af5e
5581c5a2-80f4-4ede-932b-1f8f5ca44ac4	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	3	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
f29c5e94-bbb0-4ada-82d4-5bf52ac7f596	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	4	0.251	339dee6f-1d8f-482c-8465-a87d2650af5e
d1bb9d08-da77-4c0c-a078-ce1f0ba22e3c	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	5	0.084	339dee6f-1d8f-482c-8465-a87d2650af5e
5dc8d9b6-ad06-47d2-90ec-6a20bc129a74	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	1	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
a24a9e06-5a76-4792-b337-72be72848944	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	2	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
217c9500-c4f4-412e-aa8f-9f46feaf5995	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3a60c15d-572a-4315-9a69-7bc36208ec0b	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7214ffb6-7d53-4991-a030-2d0ea6bc9c0d	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdaad12d-3f72-4e40-bfd3-cecf238038ce	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
78f3cf7a-6103-4026-9f55-1b0559481e38	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	2	0.168	339dee6f-1d8f-482c-8465-a87d2650af5e
65ac51e3-6289-4a00-8210-abbb0e91bfbe	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	3	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
78d44a59-5bbb-499c-b979-fcca957c7944	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	4	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
f39bfe87-ba1c-4493-b506-61d0aef57d76	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	5	0.084	339dee6f-1d8f-482c-8465-a87d2650af5e
6458f6ad-bcfb-4606-8235-091af0579744	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ae54c1dc-a715-4734-ac94-bfe70211b2f2	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	2	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
13536a42-e38e-4a57-adce-367b60ac2d5e	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	3	0.670	339dee6f-1d8f-482c-8465-a87d2650af5e
b00c51d6-1906-4892-87d6-4cc2e4a10b55	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	4	0.670	339dee6f-1d8f-482c-8465-a87d2650af5e
162e036d-7f58-4b3c-a3be-fe8c3f65d9db	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	5	0.084	339dee6f-1d8f-482c-8465-a87d2650af5e
c4dbcd4d-be2f-4465-8574-7a57a08ed278	107a8b49-cfb7-49d4-a3dd-f45d256664ae	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7b4f4715-c703-47ac-a41d-aaaf0d87c468	107a8b49-cfb7-49d4-a3dd-f45d256664ae	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
87955a7e-568b-49d4-a33e-8c05ee020080	107a8b49-cfb7-49d4-a3dd-f45d256664ae	6	3	0.281	339dee6f-1d8f-482c-8465-a87d2650af5e
36d8033b-3934-42aa-899e-b44d96366bde	107a8b49-cfb7-49d4-a3dd-f45d256664ae	6	4	0.518	339dee6f-1d8f-482c-8465-a87d2650af5e
12a30cd7-a515-453e-9963-961291821b43	107a8b49-cfb7-49d4-a3dd-f45d256664ae	6	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
f3d7af20-4836-4655-8d6d-d4e8ec7ea030	107a8b49-cfb7-49d4-a3dd-f45d256664ae	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dc478e77-c681-4cd9-9284-c3b1b32ceab5	107a8b49-cfb7-49d4-a3dd-f45d256664ae	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
57097b22-cfcc-4a9a-b16d-8d179b087c83	107a8b49-cfb7-49d4-a3dd-f45d256664ae	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
33807bd4-556c-4883-aafa-5bd167ba4157	107a8b49-cfb7-49d4-a3dd-f45d256664ae	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cb52851b-e482-451c-84bd-5dec04503804	107a8b49-cfb7-49d4-a3dd-f45d256664ae	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ea550142-0fce-471e-a7bd-5c9cd9fa3088	107a8b49-cfb7-49d4-a3dd-f45d256664ae	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b799d348-297d-49f2-bda0-ba7fc1e10427	107a8b49-cfb7-49d4-a3dd-f45d256664ae	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
033879a9-6a3f-4c20-928b-404d4cbcdac2	107a8b49-cfb7-49d4-a3dd-f45d256664ae	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7ee1567b-68fd-429c-92a6-c4a0ec0817ca	107a8b49-cfb7-49d4-a3dd-f45d256664ae	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63e6041d-3a82-4f94-91c5-8d0058c6678b	107a8b49-cfb7-49d4-a3dd-f45d256664ae	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8c588d7e-b050-4054-b241-c8f1f68eeb85	107a8b49-cfb7-49d4-a3dd-f45d256664ae	9	1	0.130	339dee6f-1d8f-482c-8465-a87d2650af5e
ea5d4554-b692-45cc-8f3e-17339890b750	107a8b49-cfb7-49d4-a3dd-f45d256664ae	9	2	0.216	339dee6f-1d8f-482c-8465-a87d2650af5e
1c5ae22f-9ab9-400a-9f50-3d1e885a71a6	107a8b49-cfb7-49d4-a3dd-f45d256664ae	9	3	0.432	339dee6f-1d8f-482c-8465-a87d2650af5e
4b773f61-6c1f-441a-ae74-b89cf78ff1cf	107a8b49-cfb7-49d4-a3dd-f45d256664ae	9	4	0.173	339dee6f-1d8f-482c-8465-a87d2650af5e
924c938c-c285-46f8-815e-4abcd2d01602	107a8b49-cfb7-49d4-a3dd-f45d256664ae	9	5	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
f0eb3dba-9593-45f7-ab7f-301b2013f159	107a8b49-cfb7-49d4-a3dd-f45d256664ae	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d1e3542f-381e-414e-ad35-c23dbb477b09	107a8b49-cfb7-49d4-a3dd-f45d256664ae	10	2	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
17e3e418-8800-4c64-a1a6-f19524daa978	107a8b49-cfb7-49d4-a3dd-f45d256664ae	10	3	0.173	339dee6f-1d8f-482c-8465-a87d2650af5e
a52bf272-9e2a-404c-ac55-5604f081caf0	107a8b49-cfb7-49d4-a3dd-f45d256664ae	10	4	0.173	339dee6f-1d8f-482c-8465-a87d2650af5e
69ac7991-1f81-4bc4-8fa1-4aad84a2f76c	107a8b49-cfb7-49d4-a3dd-f45d256664ae	10	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
c3376fc0-6547-4c3f-b627-8daddfc6ee55	107a8b49-cfb7-49d4-a3dd-f45d256664ae	11	1	0.084	339dee6f-1d8f-482c-8465-a87d2650af5e
d9c8980d-1684-4850-ac20-480b3adba237	107a8b49-cfb7-49d4-a3dd-f45d256664ae	11	2	0.134	339dee6f-1d8f-482c-8465-a87d2650af5e
46b2e6cc-6df1-4eaa-9604-4737c5534755	107a8b49-cfb7-49d4-a3dd-f45d256664ae	11	3	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
fcca5870-7b0b-4345-aa14-8124cd6634f1	107a8b49-cfb7-49d4-a3dd-f45d256664ae	11	4	0.335	339dee6f-1d8f-482c-8465-a87d2650af5e
fffee9a5-b90d-4bc4-9d54-c98baa845fdf	107a8b49-cfb7-49d4-a3dd-f45d256664ae	11	5	0.084	339dee6f-1d8f-482c-8465-a87d2650af5e
8717cee8-8a6d-47b6-adb3-d6fdd3069410	107a8b49-cfb7-49d4-a3dd-f45d256664ae	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
372ddd9f-ffb4-4508-a5bc-1a16cf77ac90	107a8b49-cfb7-49d4-a3dd-f45d256664ae	12	2	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
a34cbfdd-558a-497c-b3b9-1ff873717ad6	107a8b49-cfb7-49d4-a3dd-f45d256664ae	12	3	0.346	339dee6f-1d8f-482c-8465-a87d2650af5e
c623af26-6c3f-4598-bb5e-b388446bd6e9	107a8b49-cfb7-49d4-a3dd-f45d256664ae	12	4	0.346	339dee6f-1d8f-482c-8465-a87d2650af5e
eebaf77a-f3f6-4c65-b1f3-dcdd217300b6	107a8b49-cfb7-49d4-a3dd-f45d256664ae	12	5	0.054	339dee6f-1d8f-482c-8465-a87d2650af5e
08e372fd-f63e-47d0-bd18-ea5d5ff4190c	107a8b49-cfb7-49d4-a3dd-f45d256664ae	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b38d6d24-6793-4679-b1d4-3c056b0f139d	107a8b49-cfb7-49d4-a3dd-f45d256664ae	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
84d3a203-4099-41ea-8993-3bfaec04c0fb	107a8b49-cfb7-49d4-a3dd-f45d256664ae	13	3	0.259	339dee6f-1d8f-482c-8465-a87d2650af5e
0c4f79fa-bf11-4e1d-9109-7b4427faab00	107a8b49-cfb7-49d4-a3dd-f45d256664ae	13	4	0.311	339dee6f-1d8f-482c-8465-a87d2650af5e
af66be77-56df-4c11-93cd-2a3d63bee0ad	107a8b49-cfb7-49d4-a3dd-f45d256664ae	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1570d3db-e6cc-4f9a-be37-cfec768b3739	107a8b49-cfb7-49d4-a3dd-f45d256664ae	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9a292abe-091c-4fda-8720-4b3e62f68173	107a8b49-cfb7-49d4-a3dd-f45d256664ae	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2a5e6701-cfbf-4e4b-91ff-7ed8eabff4ca	107a8b49-cfb7-49d4-a3dd-f45d256664ae	14	3	0.032	339dee6f-1d8f-482c-8465-a87d2650af5e
63e7a717-00d5-45ea-810d-4d2059254a17	107a8b49-cfb7-49d4-a3dd-f45d256664ae	14	4	0.032	339dee6f-1d8f-482c-8465-a87d2650af5e
107950d1-b0d7-46dd-8042-da86fd90bc2c	107a8b49-cfb7-49d4-a3dd-f45d256664ae	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9209b684-30d8-4ce4-9efc-07b11d815e12	107a8b49-cfb7-49d4-a3dd-f45d256664ae	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
14a7699b-dbf5-4200-ac3b-45801642c811	107a8b49-cfb7-49d4-a3dd-f45d256664ae	15	2	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
942363b3-4428-48ac-985d-c316918b7d89	107a8b49-cfb7-49d4-a3dd-f45d256664ae	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
228d8bdc-9f0a-4337-a471-b3d04accca2c	107a8b49-cfb7-49d4-a3dd-f45d256664ae	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
560585b3-1137-4e59-b367-dadb772d65b5	107a8b49-cfb7-49d4-a3dd-f45d256664ae	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2ae6b457-f38e-479e-ba44-9f83963ee1ce	107a8b49-cfb7-49d4-a3dd-f45d256664ae	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ca65baa8-2f9c-4846-9552-335f1b46f659	107a8b49-cfb7-49d4-a3dd-f45d256664ae	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cfddfa27-2c65-4019-8236-689d4325b6d2	107a8b49-cfb7-49d4-a3dd-f45d256664ae	16	3	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
4290a998-3482-4c56-ae33-e27ac8e2194a	107a8b49-cfb7-49d4-a3dd-f45d256664ae	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
33a8d19a-3c42-41bf-a23a-f8887935a80f	107a8b49-cfb7-49d4-a3dd-f45d256664ae	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0eda2041-84df-4a1e-913a-7214a10ccf4e	107a8b49-cfb7-49d4-a3dd-f45d256664ae	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
168d0270-19df-4e4b-9ef3-559d620592dd	107a8b49-cfb7-49d4-a3dd-f45d256664ae	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ccbfc7a3-3cb9-4bee-9eab-52e75b17551f	107a8b49-cfb7-49d4-a3dd-f45d256664ae	17	3	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
a779ff43-3617-4eed-b9b4-78f3f0391dd8	107a8b49-cfb7-49d4-a3dd-f45d256664ae	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5d36ab4e-2396-49e7-8892-79747c376366	107a8b49-cfb7-49d4-a3dd-f45d256664ae	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
578fb24e-5b91-45d2-ba10-834c202272d5	107a8b49-cfb7-49d4-a3dd-f45d256664ae	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
60170d32-4599-43ee-9587-16c33f1c71d2	107a8b49-cfb7-49d4-a3dd-f45d256664ae	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
31353f5c-1291-41fe-ac4a-439d47dfb695	107a8b49-cfb7-49d4-a3dd-f45d256664ae	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c198bb42-2e3b-4635-9f10-15c420a3e884	107a8b49-cfb7-49d4-a3dd-f45d256664ae	18	4	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
3c23473e-beea-4098-a54a-50ced6d5a823	107a8b49-cfb7-49d4-a3dd-f45d256664ae	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
587c5531-7778-4d10-ba25-bcc6279fddda	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	1	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
96e75b11-fbbd-4df6-b4da-2f40bb5734c7	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
55473082-6468-4f49-9207-a233a322de7b	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
cbd9b0aa-204d-4cbf-8792-5e1b279c7ce0	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
40d1ed8a-bc4d-44cb-879c-51898e4ec32b	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
2ba8558a-8307-46a8-b715-4307ae6936ac	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	1	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
eb253d93-8e0b-4bba-85c1-8c83698b761a	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
6ab39540-aab6-40f8-a4cb-fc3707dddf9d	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
419497a0-9da5-468e-97f8-31a839060c38	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
c841f2fc-a2da-483d-bbf8-5d7ef6698876	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
102fb489-e334-4ee7-871c-3cb007197fdd	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	1	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
2ffba03b-6047-4729-9fcc-3ecb2aac65f4	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	2	0.174	339dee6f-1d8f-482c-8465-a87d2650af5e
d519adcd-7977-462b-adcc-164a33f73e06	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5996d610-d533-4573-90d7-be43d73c3fe5	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bd6ac90b-e7c2-4494-a4eb-4ad01e8eb50b	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
199f94bb-0ff7-40e7-8041-017058ebfe88	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
368be30a-0505-4fef-b972-284345538408	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	2	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
ea02b619-6784-4e1c-8159-6773dde14095	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
c90baad2-0d06-4b17-b3c7-e95b43b6bc5a	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
e691cab9-f153-4e27-ac42-bb4adc0b851d	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
7c3d71bf-f897-43cc-8d91-05e88c91e276	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1871c321-2282-4eda-bd68-d67c41fbefb1	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	2	1.125	339dee6f-1d8f-482c-8465-a87d2650af5e
5ef0d732-73bd-44ec-b1d9-ac760e450ccc	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	3	2.250	339dee6f-1d8f-482c-8465-a87d2650af5e
30cdb9bf-68e0-45d9-ab23-632595bbc890	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	4	2.250	339dee6f-1d8f-482c-8465-a87d2650af5e
7bd03504-bc17-498a-999c-f60410c56f7c	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	5	0.281	339dee6f-1d8f-482c-8465-a87d2650af5e
c7a2802b-6d72-4a7e-aed9-bd1c9540caa6	49463a9e-bc7c-4513-930a-23dd60afa6ff	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d885c9bd-38b1-4bf2-9995-25eccee3e19c	49463a9e-bc7c-4513-930a-23dd60afa6ff	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
56c96cc0-c401-451c-8b3f-b949b03a7791	49463a9e-bc7c-4513-930a-23dd60afa6ff	6	3	0.942	339dee6f-1d8f-482c-8465-a87d2650af5e
ff0ce2fc-b742-483d-bad0-0af5aa990564	49463a9e-bc7c-4513-930a-23dd60afa6ff	6	4	2.174	339dee6f-1d8f-482c-8465-a87d2650af5e
5e08b20a-8216-4904-8f92-2e36a0e3294e	49463a9e-bc7c-4513-930a-23dd60afa6ff	6	5	0.145	339dee6f-1d8f-482c-8465-a87d2650af5e
3024f199-6a42-479d-8416-8ad11592ed9a	49463a9e-bc7c-4513-930a-23dd60afa6ff	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
75093d31-c600-402e-97e7-ff69f765ed04	49463a9e-bc7c-4513-930a-23dd60afa6ff	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
313a8613-f405-4637-85c6-dbea8907bfb6	49463a9e-bc7c-4513-930a-23dd60afa6ff	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b095bcea-1410-475c-8eb1-2a76d6ddea4f	49463a9e-bc7c-4513-930a-23dd60afa6ff	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
73631a67-48ae-41bb-94b8-708b39567dc1	49463a9e-bc7c-4513-930a-23dd60afa6ff	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2a00082f-9f54-4e36-8874-74af8bacb82c	49463a9e-bc7c-4513-930a-23dd60afa6ff	8	1	0.507	339dee6f-1d8f-482c-8465-a87d2650af5e
c7fce05b-b674-460d-b13d-974c961bfdca	49463a9e-bc7c-4513-930a-23dd60afa6ff	8	2	1.449	339dee6f-1d8f-482c-8465-a87d2650af5e
51ebb300-058f-40af-b731-1c02e393524e	49463a9e-bc7c-4513-930a-23dd60afa6ff	8	3	1.449	339dee6f-1d8f-482c-8465-a87d2650af5e
4092cda1-5cdc-4ab1-8a5f-83fef1bfbdb3	49463a9e-bc7c-4513-930a-23dd60afa6ff	8	4	0.725	339dee6f-1d8f-482c-8465-a87d2650af5e
dd2ea476-d401-4511-8443-0474d0271a19	49463a9e-bc7c-4513-930a-23dd60afa6ff	8	5	0.290	339dee6f-1d8f-482c-8465-a87d2650af5e
897b9fff-280e-4869-9de8-5b91ae04477a	49463a9e-bc7c-4513-930a-23dd60afa6ff	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
825cd081-606d-4273-8635-a9299eaeea41	49463a9e-bc7c-4513-930a-23dd60afa6ff	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
53cf4998-e959-4ff4-b37b-1a7884bc616b	49463a9e-bc7c-4513-930a-23dd60afa6ff	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cff1e25-f1c0-4157-85ff-d1632574be8a	49463a9e-bc7c-4513-930a-23dd60afa6ff	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
25337e76-afdb-437d-a17f-4a422f9171a1	49463a9e-bc7c-4513-930a-23dd60afa6ff	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8dc92ccb-ef45-4ba9-abba-988a16091acf	49463a9e-bc7c-4513-930a-23dd60afa6ff	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a334ca50-2ecc-4229-aca8-b142a3d44323	49463a9e-bc7c-4513-930a-23dd60afa6ff	10	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dca1bbfc-9b66-4dd6-b1e9-4965991ff74d	49463a9e-bc7c-4513-930a-23dd60afa6ff	10	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7cc308b9-7dcc-49b7-a72a-88d2a8219067	49463a9e-bc7c-4513-930a-23dd60afa6ff	10	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ebe02adf-a0f4-414b-9785-9ca917c844e3	49463a9e-bc7c-4513-930a-23dd60afa6ff	10	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a8f76ce6-a053-4ff7-9ade-4c08f29face4	49463a9e-bc7c-4513-930a-23dd60afa6ff	11	1	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
452cc6d5-d95f-4ce7-8e8d-ab3f3039d599	49463a9e-bc7c-4513-930a-23dd60afa6ff	11	2	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
bea303f5-7641-4234-a1cb-4d70dd49198e	49463a9e-bc7c-4513-930a-23dd60afa6ff	11	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
221d7dfa-4885-439b-bb7a-15018f938bf8	49463a9e-bc7c-4513-930a-23dd60afa6ff	11	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
84af23e9-206b-437c-83c0-1d50a561389c	49463a9e-bc7c-4513-930a-23dd60afa6ff	11	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
d4de20cd-5e96-4652-a749-29973db39da5	49463a9e-bc7c-4513-930a-23dd60afa6ff	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dcc588f3-21fe-4082-b8d6-f7f692df2724	49463a9e-bc7c-4513-930a-23dd60afa6ff	12	2	0.362	339dee6f-1d8f-482c-8465-a87d2650af5e
18c0ca70-367b-4b0d-a14f-87a379b07997	49463a9e-bc7c-4513-930a-23dd60afa6ff	12	3	2.898	339dee6f-1d8f-482c-8465-a87d2650af5e
a483f423-34e5-4832-950f-93bcaff1757e	49463a9e-bc7c-4513-930a-23dd60afa6ff	12	4	3.623	339dee6f-1d8f-482c-8465-a87d2650af5e
2eb456ef-678f-4df2-b746-4221fb520a01	49463a9e-bc7c-4513-930a-23dd60afa6ff	12	5	0.181	339dee6f-1d8f-482c-8465-a87d2650af5e
0fd30e5c-8cc1-4804-a09d-1cd8e8eb8d6b	49463a9e-bc7c-4513-930a-23dd60afa6ff	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8c3ddae9-3248-4ab3-ac79-c100b99e8162	49463a9e-bc7c-4513-930a-23dd60afa6ff	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ce6cbc31-e7ab-4602-824f-835ce3d39822	49463a9e-bc7c-4513-930a-23dd60afa6ff	13	3	0.869	339dee6f-1d8f-482c-8465-a87d2650af5e
af35aca7-bd2e-4034-9d50-a472ac279180	49463a9e-bc7c-4513-930a-23dd60afa6ff	13	4	1.043	339dee6f-1d8f-482c-8465-a87d2650af5e
6911bcc2-7dbc-4515-8d64-fcbe0051e7de	49463a9e-bc7c-4513-930a-23dd60afa6ff	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7dcf7a2c-5118-485d-aac3-d424e2192385	49463a9e-bc7c-4513-930a-23dd60afa6ff	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b72e13f3-7dd7-432d-a748-bece9fc6ec6a	49463a9e-bc7c-4513-930a-23dd60afa6ff	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c467ab63-1fdc-41a7-9b46-f0d6536d109e	49463a9e-bc7c-4513-930a-23dd60afa6ff	14	3	0.109	339dee6f-1d8f-482c-8465-a87d2650af5e
de24c867-6218-49a5-9759-637844776b53	49463a9e-bc7c-4513-930a-23dd60afa6ff	14	4	0.109	339dee6f-1d8f-482c-8465-a87d2650af5e
239882f0-2f3a-4c44-9d3a-14b91883435e	49463a9e-bc7c-4513-930a-23dd60afa6ff	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
88c5cda1-d3ae-4fb1-ac10-bb6e294920e6	49463a9e-bc7c-4513-930a-23dd60afa6ff	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5f61282c-769b-40c1-98f1-224d4025df07	49463a9e-bc7c-4513-930a-23dd60afa6ff	15	2	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
0c1ed50e-91c7-4db7-8193-17275541b379	49463a9e-bc7c-4513-930a-23dd60afa6ff	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ee7ef244-025d-41d2-a44c-1f2807cddb5c	49463a9e-bc7c-4513-930a-23dd60afa6ff	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3a9aa79e-4d61-4754-ad3d-a7c09fd83629	49463a9e-bc7c-4513-930a-23dd60afa6ff	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b556a6d8-1915-4fcc-b90d-4a987dfcba4a	49463a9e-bc7c-4513-930a-23dd60afa6ff	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c5f58fdf-1d9a-42c8-85a3-a7b4c4273c04	49463a9e-bc7c-4513-930a-23dd60afa6ff	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3e1cd24f-aa36-4ff6-8d63-0ddf5eb35001	49463a9e-bc7c-4513-930a-23dd60afa6ff	16	3	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
684d82c7-21b2-4850-8d0b-80e4a360ad72	49463a9e-bc7c-4513-930a-23dd60afa6ff	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
26488c8b-71df-4f9c-924d-2da9900e1be1	49463a9e-bc7c-4513-930a-23dd60afa6ff	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
22706912-6a37-433b-8c9b-8075c6b47874	49463a9e-bc7c-4513-930a-23dd60afa6ff	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82d2e449-35c2-45b8-bcdd-187f0ea89a8b	49463a9e-bc7c-4513-930a-23dd60afa6ff	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
99ac5f4c-ea73-46ef-a01a-cdf4cf836548	49463a9e-bc7c-4513-930a-23dd60afa6ff	17	3	0.290	339dee6f-1d8f-482c-8465-a87d2650af5e
4e0b69cd-c93e-462d-aa49-4d21e72c3aeb	49463a9e-bc7c-4513-930a-23dd60afa6ff	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3ba28c3c-b3ff-4dd1-9b16-f7e6f356cae8	49463a9e-bc7c-4513-930a-23dd60afa6ff	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1e672349-6391-48ee-ac09-6a6a447c211d	49463a9e-bc7c-4513-930a-23dd60afa6ff	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
272e7ec6-c8dc-425a-aad7-f8591135bd3f	49463a9e-bc7c-4513-930a-23dd60afa6ff	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f85716b3-1b3b-4e61-aa1c-dcd7da783ebb	49463a9e-bc7c-4513-930a-23dd60afa6ff	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a0e5c6e5-2d2b-4386-bdde-080d85555450	49463a9e-bc7c-4513-930a-23dd60afa6ff	18	4	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
7f5d0d7a-7946-428e-a667-7c8da2b11cea	49463a9e-bc7c-4513-930a-23dd60afa6ff	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
48af49dc-faea-4acd-b964-bd0fe434a028	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
20cf8514-8335-40c4-8560-fad15e32e2b8	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
959613ef-34d3-495a-82bd-0c4e95e8d5fd	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b70235fa-9a2a-4e34-8d45-4170c4cc6af9	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0dbf7fda-02cb-4cdd-83c0-f68d9ee09608	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
75b9bb94-fbdd-44ec-9943-6bf5b789804d	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6f51ea2d-4c69-4bc5-a3d9-011a943cda30	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
da6d4422-3ecc-49e5-bff1-c2f6e53b3c00	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
944f9c05-ce88-4c08-b98d-16258273b6e0	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
04f0a173-139c-4f23-b420-17f5ca104f54	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1b6def97-1148-4aeb-a619-a096cf0e5228	6a7a2c65-ff00-4138-b231-08ef30abbea6	3	1	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
341ea09d-23ed-46c2-a072-34259fadd6d3	6a7a2c65-ff00-4138-b231-08ef30abbea6	3	2	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
e5a752df-d662-4ba5-ba60-8682d4412aeb	6a7a2c65-ff00-4138-b231-08ef30abbea6	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32087c04-ec74-44f8-927c-315d26d43002	6a7a2c65-ff00-4138-b231-08ef30abbea6	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0213619-1e24-47d4-b5d2-440116290b3a	6a7a2c65-ff00-4138-b231-08ef30abbea6	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1b5bc88c-f7b9-4fb8-b1a9-fda1fceac91e	6a7a2c65-ff00-4138-b231-08ef30abbea6	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a2febee8-5919-4519-ad6f-191bf9a18646	6a7a2c65-ff00-4138-b231-08ef30abbea6	4	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c6041621-547b-4c38-afb5-65014f9d707f	6a7a2c65-ff00-4138-b231-08ef30abbea6	4	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
349d789a-978c-45c8-8045-ec9e8ca479c9	6a7a2c65-ff00-4138-b231-08ef30abbea6	4	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3efa508e-ac5e-4cbb-9eea-0f3afe0e0ba5	6a7a2c65-ff00-4138-b231-08ef30abbea6	4	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
caf8f256-893c-4b79-bd30-a3162449f1f3	6a7a2c65-ff00-4138-b231-08ef30abbea6	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aff5744c-0925-437d-864e-36a518ea38a4	6a7a2c65-ff00-4138-b231-08ef30abbea6	5	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
644ad333-8035-43e5-9042-45bd13348ad3	6a7a2c65-ff00-4138-b231-08ef30abbea6	5	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54c9f4f6-d108-46e2-947e-7576f16256e1	6a7a2c65-ff00-4138-b231-08ef30abbea6	5	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f55233ce-ca64-412c-80c8-839867cc9070	6a7a2c65-ff00-4138-b231-08ef30abbea6	5	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54c813c7-7af8-4b4a-a946-723585554de8	6a7a2c65-ff00-4138-b231-08ef30abbea6	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4ab32503-caf7-4e6c-8212-e157bf49c153	6a7a2c65-ff00-4138-b231-08ef30abbea6	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
024e68d9-a948-40c3-b0c4-8ec2ac1a3780	6a7a2c65-ff00-4138-b231-08ef30abbea6	6	3	0.219	339dee6f-1d8f-482c-8465-a87d2650af5e
2029ddfd-fcd2-403d-ad1b-3a65f61aad7e	6a7a2c65-ff00-4138-b231-08ef30abbea6	6	4	0.405	339dee6f-1d8f-482c-8465-a87d2650af5e
b94ed4c9-79a0-415e-94d7-5c732d07cbaa	6a7a2c65-ff00-4138-b231-08ef30abbea6	6	5	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
c5518c5a-c8aa-4c84-b66c-da4bdaf70ae2	6a7a2c65-ff00-4138-b231-08ef30abbea6	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0b953f27-e796-4a55-bafd-6f573fecc5f7	6a7a2c65-ff00-4138-b231-08ef30abbea6	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
20461ffc-0651-4eba-b24f-8601c9719457	6a7a2c65-ff00-4138-b231-08ef30abbea6	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b8c54370-edf0-41c8-b236-a12acb047b8c	6a7a2c65-ff00-4138-b231-08ef30abbea6	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f8dc7ba5-3414-4481-a714-35e38906f26f	6a7a2c65-ff00-4138-b231-08ef30abbea6	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
52b4fd42-3934-4509-884d-ea08465037de	6a7a2c65-ff00-4138-b231-08ef30abbea6	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e62fdd0e-1632-4444-a3a7-97893795c4d9	6a7a2c65-ff00-4138-b231-08ef30abbea6	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
64e46394-96f1-4679-b2e6-79a764a13998	6a7a2c65-ff00-4138-b231-08ef30abbea6	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32618273-dff1-4692-8fe4-a434888d1653	6a7a2c65-ff00-4138-b231-08ef30abbea6	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7cd5c046-0f8a-481e-a8d8-69630348a431	6a7a2c65-ff00-4138-b231-08ef30abbea6	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c355aef4-e0db-4be0-966f-e6baf77d8f30	6a7a2c65-ff00-4138-b231-08ef30abbea6	9	1	0.101	339dee6f-1d8f-482c-8465-a87d2650af5e
77571597-636a-446c-9f06-e2e0791b16df	6a7a2c65-ff00-4138-b231-08ef30abbea6	9	2	0.169	339dee6f-1d8f-482c-8465-a87d2650af5e
b18fedc5-9889-40b1-a3f1-d7c58b2a7fa2	6a7a2c65-ff00-4138-b231-08ef30abbea6	9	3	0.337	339dee6f-1d8f-482c-8465-a87d2650af5e
8ec53a31-f37f-49a9-95a7-4184785928c8	6a7a2c65-ff00-4138-b231-08ef30abbea6	9	4	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
779b2392-71a8-46f6-9774-ac39f2cf539f	6a7a2c65-ff00-4138-b231-08ef30abbea6	9	5	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
6d91e921-0d05-4b52-af0e-c0fee08f8fbc	6a7a2c65-ff00-4138-b231-08ef30abbea6	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
925717a3-4b9e-4617-b7e8-670df42a8b62	6a7a2c65-ff00-4138-b231-08ef30abbea6	10	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
dc6dcb52-b722-4eb4-bc3a-e753aeb67094	6a7a2c65-ff00-4138-b231-08ef30abbea6	10	3	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
55f26222-6079-4ba6-9173-8c5838974443	6a7a2c65-ff00-4138-b231-08ef30abbea6	10	4	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
d7182241-e894-4ea8-a8f5-1b72f009598f	6a7a2c65-ff00-4138-b231-08ef30abbea6	10	5	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
c4428cc2-ca98-4b98-bfee-909c37d75635	6a7a2c65-ff00-4138-b231-08ef30abbea6	11	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a54fa167-636b-45ef-8be2-e523bb1f0d37	6a7a2c65-ff00-4138-b231-08ef30abbea6	11	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
906358e6-4ed4-4a68-8d1e-d993560abd13	6a7a2c65-ff00-4138-b231-08ef30abbea6	11	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
68b71e4d-3d7f-4010-bedf-ed01d4a280dc	6a7a2c65-ff00-4138-b231-08ef30abbea6	11	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
15584e64-212d-4dd0-8eee-3195c297851b	6a7a2c65-ff00-4138-b231-08ef30abbea6	11	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aece6516-5b33-4713-82f6-51e425757042	6a7a2c65-ff00-4138-b231-08ef30abbea6	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5bbbd576-56da-43ab-b877-2784e14a0ff6	6a7a2c65-ff00-4138-b231-08ef30abbea6	12	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
f29e1537-add8-48b7-912a-7d40cb48b3f5	6a7a2c65-ff00-4138-b231-08ef30abbea6	12	3	0.270	339dee6f-1d8f-482c-8465-a87d2650af5e
51e5d3e4-1532-4bc7-beff-6a95787fb03c	6a7a2c65-ff00-4138-b231-08ef30abbea6	12	4	0.270	339dee6f-1d8f-482c-8465-a87d2650af5e
3f4c5603-dc3a-474b-ba16-9dc46babd9aa	6a7a2c65-ff00-4138-b231-08ef30abbea6	12	5	0.042	339dee6f-1d8f-482c-8465-a87d2650af5e
805217d8-eea2-40fc-9357-c1ee17d0fca8	6a7a2c65-ff00-4138-b231-08ef30abbea6	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ce8b7c29-a70f-4b1d-b1fb-2445c4a797e2	6a7a2c65-ff00-4138-b231-08ef30abbea6	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c50bed89-a2a6-46f0-a423-e127a0889c81	6a7a2c65-ff00-4138-b231-08ef30abbea6	13	3	0.202	339dee6f-1d8f-482c-8465-a87d2650af5e
9e6607da-e6d8-4b8b-95fa-8a31064783ef	6a7a2c65-ff00-4138-b231-08ef30abbea6	13	4	0.243	339dee6f-1d8f-482c-8465-a87d2650af5e
92c0d93d-a2fd-4959-8259-7223e03e3f33	6a7a2c65-ff00-4138-b231-08ef30abbea6	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4359af41-29ce-4da9-a218-f2854bdcd9b3	6a7a2c65-ff00-4138-b231-08ef30abbea6	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dcb7fb9e-98d1-4607-949f-e47cf38610f5	6a7a2c65-ff00-4138-b231-08ef30abbea6	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
70805582-da29-4ed0-a39e-9df4611e9c3c	6a7a2c65-ff00-4138-b231-08ef30abbea6	14	3	0.025	339dee6f-1d8f-482c-8465-a87d2650af5e
a96694b8-b73b-4133-bb24-722448b80bd6	6a7a2c65-ff00-4138-b231-08ef30abbea6	14	4	0.025	339dee6f-1d8f-482c-8465-a87d2650af5e
875b2759-157d-40ad-bb3e-532b1c395e27	6a7a2c65-ff00-4138-b231-08ef30abbea6	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f4c93987-2d6c-4351-9121-847d0e6af30e	6a7a2c65-ff00-4138-b231-08ef30abbea6	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fe6f47e3-61b3-48ba-a2d1-7636667dae22	6a7a2c65-ff00-4138-b231-08ef30abbea6	15	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
d122515c-b88c-4f21-a1ae-9596cee6806b	6a7a2c65-ff00-4138-b231-08ef30abbea6	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
acbb59c6-f45e-4703-aaed-d47bfcc325a7	6a7a2c65-ff00-4138-b231-08ef30abbea6	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dde698d4-4af7-4596-8130-a34330947630	6a7a2c65-ff00-4138-b231-08ef30abbea6	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54a71eb2-2205-4645-849e-00882cb80772	6a7a2c65-ff00-4138-b231-08ef30abbea6	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
349f7330-dc24-4bd3-a53f-6e42c35114a2	6a7a2c65-ff00-4138-b231-08ef30abbea6	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ad28c525-8304-484e-89a7-0b3ab6a53ec3	6a7a2c65-ff00-4138-b231-08ef30abbea6	16	3	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
169e9f7a-8dc6-4e73-8a55-533db931d276	6a7a2c65-ff00-4138-b231-08ef30abbea6	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
108c1e3d-3a15-470c-8315-5f153268d21b	6a7a2c65-ff00-4138-b231-08ef30abbea6	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
027bba15-ca3e-49a7-82b2-df3119ac953c	6a7a2c65-ff00-4138-b231-08ef30abbea6	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f9fd6594-921d-49f0-9b91-4554747b3639	6a7a2c65-ff00-4138-b231-08ef30abbea6	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a974635-5900-453b-a471-2d6f10c8c402	6a7a2c65-ff00-4138-b231-08ef30abbea6	17	3	0.051	339dee6f-1d8f-482c-8465-a87d2650af5e
a9950478-a302-40f4-bce0-2bcfc0054b9f	6a7a2c65-ff00-4138-b231-08ef30abbea6	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fe8f0973-3e33-4dae-bdc0-d5e2e93520a3	6a7a2c65-ff00-4138-b231-08ef30abbea6	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2d43ed77-db93-4dff-bbda-90074b22981b	6a7a2c65-ff00-4138-b231-08ef30abbea6	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d1c9e397-91e3-43e8-954f-2f1e388f2415	6a7a2c65-ff00-4138-b231-08ef30abbea6	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
909f3ab0-0094-4658-b421-787c020f6a0d	6a7a2c65-ff00-4138-b231-08ef30abbea6	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7aba4103-2419-438b-afb1-7099543b005a	6a7a2c65-ff00-4138-b231-08ef30abbea6	18	4	0.051	339dee6f-1d8f-482c-8465-a87d2650af5e
0dfcd443-f137-44cc-ae76-ddc02f30f7e6	6a7a2c65-ff00-4138-b231-08ef30abbea6	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdf572d8-5006-49de-bdd8-152a3fd50bee	4baf4698-bff3-4fc5-b868-f8217875dc44	1	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
ce30f570-4888-4799-be45-a33ecf03e9c3	4baf4698-bff3-4fc5-b868-f8217875dc44	1	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4c9e7e0c-ac09-43a3-ad98-590502bff5b6	4baf4698-bff3-4fc5-b868-f8217875dc44	1	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
148c0ef3-2fcd-40cc-a48b-baf6592a3ab1	4baf4698-bff3-4fc5-b868-f8217875dc44	1	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a4342189-0bc8-4819-9f83-bfc9b3b0c060	4baf4698-bff3-4fc5-b868-f8217875dc44	1	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
be00e52a-e76e-4416-a5d8-6af7e33fd1b0	4baf4698-bff3-4fc5-b868-f8217875dc44	2	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
31b0163a-b33d-41b5-87e2-a78ca35be665	4baf4698-bff3-4fc5-b868-f8217875dc44	2	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
1a12bf6c-4633-45f2-8805-1b11c97d64b5	4baf4698-bff3-4fc5-b868-f8217875dc44	2	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ac6253bc-cdac-4411-97d4-1bb39b106135	4baf4698-bff3-4fc5-b868-f8217875dc44	2	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
2e0bf444-6da8-42b4-835a-e698a35392da	4baf4698-bff3-4fc5-b868-f8217875dc44	2	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
c1abbebc-3305-4643-8a09-4c0687526d91	4baf4698-bff3-4fc5-b868-f8217875dc44	3	1	0.667	339dee6f-1d8f-482c-8465-a87d2650af5e
ea8c6346-4ef3-4294-8651-f77baedf7e0a	4baf4698-bff3-4fc5-b868-f8217875dc44	3	2	0.800	339dee6f-1d8f-482c-8465-a87d2650af5e
7d25a75c-49a1-471e-8efa-1f8f63939f85	4baf4698-bff3-4fc5-b868-f8217875dc44	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fd3e0189-a8ea-4266-966f-ba52c850feaf	4baf4698-bff3-4fc5-b868-f8217875dc44	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3e22ccc5-55ba-4843-bc49-be0699728ce4	4baf4698-bff3-4fc5-b868-f8217875dc44	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6c701531-1a28-4700-a89f-74286a8e271b	4baf4698-bff3-4fc5-b868-f8217875dc44	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
838aa1be-a7b4-45a2-8e18-8e1c0f4c336e	4baf4698-bff3-4fc5-b868-f8217875dc44	4	2	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
c0cd4c05-96ef-4f13-9143-e8d4f93e3955	4baf4698-bff3-4fc5-b868-f8217875dc44	4	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9f5d6111-8aac-4e5b-9df0-e6322e7f2bc8	4baf4698-bff3-4fc5-b868-f8217875dc44	4	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e41aedc9-1d7c-4019-a822-ffab3688c14b	4baf4698-bff3-4fc5-b868-f8217875dc44	4	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
d1b785e6-6c01-48d1-9858-1b2ecdb2181b	4baf4698-bff3-4fc5-b868-f8217875dc44	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6e53aa1c-9f59-47a5-a98a-0625857cc40f	4baf4698-bff3-4fc5-b868-f8217875dc44	5	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5747a05a-db61-44ba-865d-3bd5a62f23b1	4baf4698-bff3-4fc5-b868-f8217875dc44	5	3	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
223d237f-4726-4b9f-b307-9b7dfe4ecaef	4baf4698-bff3-4fc5-b868-f8217875dc44	5	4	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
486c11c7-90cc-45ec-bf98-f757bdf9d2bd	4baf4698-bff3-4fc5-b868-f8217875dc44	5	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
853b4403-7a96-4c66-9614-e23ba749447d	4baf4698-bff3-4fc5-b868-f8217875dc44	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
865143c3-1d51-4f35-b0a6-a9f6ddd30122	4baf4698-bff3-4fc5-b868-f8217875dc44	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
537fc84a-182d-413f-8539-ba8ad70cb0fc	4baf4698-bff3-4fc5-b868-f8217875dc44	6	3	4.335	339dee6f-1d8f-482c-8465-a87d2650af5e
ea842a09-2c06-4118-99c3-0617749fb135	4baf4698-bff3-4fc5-b868-f8217875dc44	6	4	8.003	339dee6f-1d8f-482c-8465-a87d2650af5e
1b40fc56-14dd-4b3c-b2c0-294469afc833	4baf4698-bff3-4fc5-b868-f8217875dc44	6	5	0.667	339dee6f-1d8f-482c-8465-a87d2650af5e
3231028f-b21c-49b7-a2ff-2992028bfd0e	4baf4698-bff3-4fc5-b868-f8217875dc44	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6395ef60-99e8-4918-bed1-396f520f32ae	4baf4698-bff3-4fc5-b868-f8217875dc44	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4c3d7d25-eb4a-4133-b0fd-003bc5231bad	4baf4698-bff3-4fc5-b868-f8217875dc44	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c3c2da39-4b3e-46ec-af73-100aa12126ca	4baf4698-bff3-4fc5-b868-f8217875dc44	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c4f1750b-be6a-4f6e-b4f2-a317097e5c2d	4baf4698-bff3-4fc5-b868-f8217875dc44	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
95ed7d18-1c35-45fb-8df6-8d7e1aad376b	4baf4698-bff3-4fc5-b868-f8217875dc44	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5f9ef508-7746-4228-85bd-f27e27a403b6	4baf4698-bff3-4fc5-b868-f8217875dc44	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e10a53f9-39d9-4ae5-90d8-ee219a4eb973	4baf4698-bff3-4fc5-b868-f8217875dc44	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7837642f-1435-438e-95d0-f2b84ee10276	4baf4698-bff3-4fc5-b868-f8217875dc44	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e64edbca-f359-4444-af90-a0ced26a783c	4baf4698-bff3-4fc5-b868-f8217875dc44	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
087d0025-b43f-446c-8544-bdcb3f35bff2	4baf4698-bff3-4fc5-b868-f8217875dc44	9	1	2.001	339dee6f-1d8f-482c-8465-a87d2650af5e
6a59394a-8056-4a27-b5c0-9d7d52b3d51a	4baf4698-bff3-4fc5-b868-f8217875dc44	9	2	3.335	339dee6f-1d8f-482c-8465-a87d2650af5e
443ed8bf-1b23-4818-8f89-f878390bb792	4baf4698-bff3-4fc5-b868-f8217875dc44	9	3	6.669	339dee6f-1d8f-482c-8465-a87d2650af5e
054bfac8-755e-4cda-a3de-bf47aa2c2c96	4baf4698-bff3-4fc5-b868-f8217875dc44	9	4	2.668	339dee6f-1d8f-482c-8465-a87d2650af5e
86937004-357b-4368-a05d-3b6e23eadbc6	4baf4698-bff3-4fc5-b868-f8217875dc44	9	5	1.334	339dee6f-1d8f-482c-8465-a87d2650af5e
4bfa1c16-28eb-41c5-8e32-23eb07c0b76b	4baf4698-bff3-4fc5-b868-f8217875dc44	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5939644e-2a90-49d9-92c2-43be8494fcd9	4baf4698-bff3-4fc5-b868-f8217875dc44	10	2	1.334	339dee6f-1d8f-482c-8465-a87d2650af5e
628cf509-4ec8-4e18-adfa-ee0b3021d856	4baf4698-bff3-4fc5-b868-f8217875dc44	10	3	2.668	339dee6f-1d8f-482c-8465-a87d2650af5e
d62af1eb-c650-4159-9a7b-b15a6a02cbfd	4baf4698-bff3-4fc5-b868-f8217875dc44	10	4	2.668	339dee6f-1d8f-482c-8465-a87d2650af5e
86345d72-3e25-4ed8-b957-e756aab0ae14	4baf4698-bff3-4fc5-b868-f8217875dc44	10	5	0.667	339dee6f-1d8f-482c-8465-a87d2650af5e
203656e3-a228-4d92-ae1b-6a4e0d11e5f6	4baf4698-bff3-4fc5-b868-f8217875dc44	11	1	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
7e7e1ff4-513f-441b-8a28-db8e5084caac	4baf4698-bff3-4fc5-b868-f8217875dc44	11	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
07bcebea-d64a-4049-9904-1d5a9b66b20a	4baf4698-bff3-4fc5-b868-f8217875dc44	11	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e79f8af1-d39b-4d79-b849-d609ef55121d	4baf4698-bff3-4fc5-b868-f8217875dc44	11	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d841c991-eaf4-43dc-9eda-1cf236d845b7	4baf4698-bff3-4fc5-b868-f8217875dc44	11	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
6dee60b7-0879-4ccc-a2e8-1329cae0ac55	4baf4698-bff3-4fc5-b868-f8217875dc44	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
516f4b8e-e6a3-4803-a8a4-5e265c0026cd	4baf4698-bff3-4fc5-b868-f8217875dc44	12	2	1.334	339dee6f-1d8f-482c-8465-a87d2650af5e
90860a97-d4c5-4b5d-a7e2-d742191186fe	4baf4698-bff3-4fc5-b868-f8217875dc44	12	3	5.335	339dee6f-1d8f-482c-8465-a87d2650af5e
09e72202-34f3-4626-8cb0-a856f86feff9	4baf4698-bff3-4fc5-b868-f8217875dc44	12	4	5.335	339dee6f-1d8f-482c-8465-a87d2650af5e
ea5f0ce7-c2af-4722-ba67-86260a671b60	4baf4698-bff3-4fc5-b868-f8217875dc44	12	5	0.834	339dee6f-1d8f-482c-8465-a87d2650af5e
4be34aba-24c1-460d-ba8c-c681798c3293	4baf4698-bff3-4fc5-b868-f8217875dc44	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
637ffb9a-7a49-4365-b87e-c1952e9ac7ed	4baf4698-bff3-4fc5-b868-f8217875dc44	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d165b41d-9fa9-47f0-ae75-17dbd1ae0a66	4baf4698-bff3-4fc5-b868-f8217875dc44	13	3	4.002	339dee6f-1d8f-482c-8465-a87d2650af5e
1233895e-c943-4e0f-90ca-bdf421a2c147	4baf4698-bff3-4fc5-b868-f8217875dc44	13	4	4.802	339dee6f-1d8f-482c-8465-a87d2650af5e
7c7971e7-90ea-44ed-bd3b-f3d976a281b5	4baf4698-bff3-4fc5-b868-f8217875dc44	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
111dd06f-899d-4bd4-ac39-fb92c857f9ec	4baf4698-bff3-4fc5-b868-f8217875dc44	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d767d192-f987-4b4b-88fb-06a6cfe83943	4baf4698-bff3-4fc5-b868-f8217875dc44	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
20836382-73ee-4a3c-a554-bd205d72d87d	4baf4698-bff3-4fc5-b868-f8217875dc44	14	3	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
5b04deb4-e43f-4f80-b1bd-8bb0bb1ab02f	4baf4698-bff3-4fc5-b868-f8217875dc44	14	4	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
5ab923f5-d22e-4d2e-8742-74735d416b96	4baf4698-bff3-4fc5-b868-f8217875dc44	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c6b6d971-c3ad-49f6-8d3c-fca40c62dd2b	4baf4698-bff3-4fc5-b868-f8217875dc44	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e29f7c34-c09c-446c-976a-fe105a6320e5	4baf4698-bff3-4fc5-b868-f8217875dc44	15	2	1.334	339dee6f-1d8f-482c-8465-a87d2650af5e
0523a8e7-7c90-468e-aebe-999e90fb1c33	4baf4698-bff3-4fc5-b868-f8217875dc44	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82038cbd-34ed-49e2-a3c7-4220ac4f5edd	4baf4698-bff3-4fc5-b868-f8217875dc44	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
243f3166-c73d-4698-b5b9-6f10c190c75c	4baf4698-bff3-4fc5-b868-f8217875dc44	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1d55e4f7-7023-49d0-acc2-12860b4f1c21	4baf4698-bff3-4fc5-b868-f8217875dc44	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8f9da0d9-20f0-42b7-86ad-534c3e815276	4baf4698-bff3-4fc5-b868-f8217875dc44	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fd712a7c-8234-4fab-9e69-833e932364ee	4baf4698-bff3-4fc5-b868-f8217875dc44	16	3	0.800	339dee6f-1d8f-482c-8465-a87d2650af5e
9953c3e6-795d-4d87-8985-670d911ca919	4baf4698-bff3-4fc5-b868-f8217875dc44	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
89aa49e0-93f0-409c-974b-728743b480fe	4baf4698-bff3-4fc5-b868-f8217875dc44	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8d506662-3b2a-4830-82e6-0acf48a68a6f	4baf4698-bff3-4fc5-b868-f8217875dc44	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
037f2779-f436-4137-94fc-569728bbfdfc	4baf4698-bff3-4fc5-b868-f8217875dc44	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
905b9c22-66cf-490e-9954-c5bb98ea7732	4baf4698-bff3-4fc5-b868-f8217875dc44	17	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
13454376-a720-4490-9730-3b511da28e88	4baf4698-bff3-4fc5-b868-f8217875dc44	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d384c639-4277-46fd-bac8-37d2e90a18f2	4baf4698-bff3-4fc5-b868-f8217875dc44	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
30f7fe3d-ce50-4b2e-83c5-7d557e8954e0	4baf4698-bff3-4fc5-b868-f8217875dc44	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8beb34bb-c442-49ed-b183-90592552d4f2	4baf4698-bff3-4fc5-b868-f8217875dc44	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fc71fc72-e310-4a84-a581-1d371862c35a	4baf4698-bff3-4fc5-b868-f8217875dc44	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4c77d2f0-451d-428b-88b2-8030c9d86a97	4baf4698-bff3-4fc5-b868-f8217875dc44	18	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5f03ad31-38af-45a0-9af3-a50a9ec45750	4baf4698-bff3-4fc5-b868-f8217875dc44	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
09d6c5cb-be47-4d5d-8b75-a8554f30b63a	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	1	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
831657b7-2e8b-493e-b0ae-60260e9bba3b	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0316cb7d-56aa-4dbe-adac-f6dc529a0c24	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bc5cc066-9090-406e-9b2a-e37124501522	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9fe0346c-ecbc-44f5-a529-15b4195fdd3e	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	5	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
d9a092eb-6137-48ac-a104-596c61135787	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	1	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
2a4fb6a5-d186-436a-93ab-43a50bcf0455	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
90b53aab-0c5d-414e-902e-e463c3a527e0	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b014d7d5-8ce2-4a33-af34-7b066726d679	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d5dd4e63-524e-4f6f-a396-40c278aec4d3	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	5	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
f1c9997e-0d6e-40ca-afa4-ad1e83b41961	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	1	2.499	339dee6f-1d8f-482c-8465-a87d2650af5e
6eb0d942-66e8-493b-93b0-dcf8e5ba7f00	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	2	1.250	339dee6f-1d8f-482c-8465-a87d2650af5e
1064fcc1-3f82-4d51-bdee-046004746a3f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	3	1.250	339dee6f-1d8f-482c-8465-a87d2650af5e
b126b5c6-2afc-418a-8161-ceff426a4015	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	4	1.250	339dee6f-1d8f-482c-8465-a87d2650af5e
d780a48a-8a23-43eb-89cc-d117fd091b61	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	5	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
184b7432-e8cf-48a6-a7d7-52611c28b6a8	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3874e35c-9f52-44a9-9b9e-e54571fd33dc	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	2	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
e70994a2-ec1f-4642-9482-d46328c2ccbf	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63eaf6b0-d13d-4de9-9677-26bffc8e9fbe	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
34592f62-8102-43a0-834f-6033107011b7	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
731ee0a3-df86-425b-a9c8-c6b14149cc3a	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dceba26d-406b-49f2-b0e7-3d406fc32e96	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	2	1.500	339dee6f-1d8f-482c-8465-a87d2650af5e
a5981b5e-97f4-4254-91f5-1bc5c4422f84	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	3	3.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b6b1b6ec-ff58-4d4d-8eef-e8613e90625f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	4	3.000	339dee6f-1d8f-482c-8465-a87d2650af5e
170bfea9-02a1-4fcf-bf4c-e59110c5640a	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	5	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
e501549f-4829-4d15-9cb0-5fb6bb9de222	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a140775-27ae-41e3-b246-8ae7d468174f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ddb17d75-01be-47be-9927-8f081178d2ae	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	6	3	16.245	339dee6f-1d8f-482c-8465-a87d2650af5e
93ad9b92-37d4-431f-bafd-e215d44235b1	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	6	4	18.744	339dee6f-1d8f-482c-8465-a87d2650af5e
2c252222-6aa2-49c7-a3b3-5a09a35aec77	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	6	5	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
be5d8d18-23dd-4ce5-853d-9f44e7c6583a	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	7	1	2.187	339dee6f-1d8f-482c-8465-a87d2650af5e
6cd6ff4a-b6af-4cf8-a4c5-dacf8c8f7a6a	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	7	2	11.246	339dee6f-1d8f-482c-8465-a87d2650af5e
0bcea847-2065-41e7-8802-c5b083811e9e	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	7	3	6.248	339dee6f-1d8f-482c-8465-a87d2650af5e
638e3936-f13e-4669-9bc3-4a602da39c09	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	7	4	3.124	339dee6f-1d8f-482c-8465-a87d2650af5e
29f50f3a-b84b-49eb-b4b1-04462720312f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	7	5	1.250	339dee6f-1d8f-482c-8465-a87d2650af5e
f382d3ff-aa95-412a-841a-b4063628061b	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
81ffdba9-f14b-4b68-b18e-62a005bd28e5	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdd50588-bbb1-4f31-b40c-d2b98f389d09	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9e666fc3-53da-4860-884a-3e307298ecfe	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
33b9eeae-e8fd-49da-8b8e-7ca12af34f98	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0b5a9b97-338b-4cf0-a486-0832c98c0efd	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
95b3e854-4ba9-49de-b703-67647147642e	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1df63f6a-7f15-4642-9827-c63bf3701462	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f2301423-bee3-4eaf-9590-88734ffcd7c7	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
098ffa77-ba15-48b3-837c-973f86192a39	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
464df042-42b1-4462-b9e3-f8d070026147	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a3a2ae6a-4799-49ef-9a1e-f1d8aff1f10d	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	10	2	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
a7c83e49-a674-4eb8-b3c7-f04f9183bc6a	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	10	3	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
af8ee28f-083a-4c11-8bc6-7eb9747fc4e2	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	10	4	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
8f29f853-dd94-4284-b49c-cce70b75328c	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	10	5	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
9df7703e-4361-429c-9d45-35c4903d5926	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	11	1	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
18d6da78-bcf5-4734-afa9-89030dfa3744	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	11	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e8b50f48-c603-4634-a3e6-026732c48a40	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	11	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
24c184bc-6775-4985-8d09-c2feddcb24b6	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	11	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7ddab484-a88b-4ec2-99d7-b06debc5b2e2	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	11	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
908e12ea-b699-433e-94b2-74c604bbab89	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5079dc7f-f036-4b6d-918e-11bf5c53b017	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	12	2	4.998	339dee6f-1d8f-482c-8465-a87d2650af5e
35519a7d-b6ae-4b7c-bf94-a2d10c72c2bb	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	12	3	9.997	339dee6f-1d8f-482c-8465-a87d2650af5e
26c29285-32f5-4230-b7fb-fdf47e0937b5	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	12	4	12.496	339dee6f-1d8f-482c-8465-a87d2650af5e
90ac6714-130a-44d8-ae74-14562cea049f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	12	5	0.625	339dee6f-1d8f-482c-8465-a87d2650af5e
840dffaa-bba2-4d6d-a770-e258b9a859dc	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5eb36f5a-fe1a-4ec9-b2a8-2c8615fb67b5	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4ca016b7-4b66-4f50-9214-ad68ca0e0429	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	13	3	7.498	339dee6f-1d8f-482c-8465-a87d2650af5e
1468f606-6ce8-4479-95a6-36d8872663e0	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	13	4	12.496	339dee6f-1d8f-482c-8465-a87d2650af5e
64121b39-af53-4bdd-b952-67245208c347	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d3233fb2-7c94-4a6b-be26-17c7844faf1d	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a61dd291-ec68-4d4c-9de6-b3e190eea679	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a20c3adb-82a9-4a24-a8b5-1250b81f277d	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	14	3	1.874	339dee6f-1d8f-482c-8465-a87d2650af5e
d99f201c-6d09-4c26-b4eb-98c6868a954e	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	14	4	1.874	339dee6f-1d8f-482c-8465-a87d2650af5e
b8cbc718-962c-458b-83ad-bfd6e9b22306	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
50a17b15-5857-4542-a7ee-a4fc28834bc7	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c023a328-ba96-4653-82b8-8e5fea8dfcb4	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	15	2	1.406	339dee6f-1d8f-482c-8465-a87d2650af5e
375060c0-9651-459d-8bbd-ad699ecf1bce	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e9680ce3-b4b5-4522-951f-2687423400d7	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
eb3addeb-110a-4c2d-9362-e92d352dd1da	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e5a90c78-09a3-4eae-a27d-4ac75de6b887	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cd2bbdce-f9fb-46a1-be1a-0148f44ad7ec	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d50fb324-1362-4082-804d-5691e5f38885	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	16	3	2.812	339dee6f-1d8f-482c-8465-a87d2650af5e
d0cbfddb-e4d0-4dcc-9211-b333d19ef37f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
132f599d-a23c-4c98-8c68-88e81478e63c	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f5058bbe-f055-4fe8-aa9e-72c0564bb0db	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4e881c8b-83ea-4fee-96a7-13118df6e5ee	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6d058980-a187-4fee-b956-2d653f707082	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	17	3	9.372	339dee6f-1d8f-482c-8465-a87d2650af5e
f8f57cca-ce29-4932-8f61-92eb6e1f232f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
67bbb9e5-e98d-4bde-b8fa-3192d1da5a1f	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d631762d-7102-41c2-914d-17a2f7ecc795	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5fb70194-2722-471d-b0ce-38a92f8871d4	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a164125b-d598-432f-86fd-123f629fe0e2	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0802c47c-2539-4314-a94f-b85ddb933385	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	18	4	1.250	339dee6f-1d8f-482c-8465-a87d2650af5e
8f34bfcc-2633-4be8-9a14-244273ed468e	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
737af28e-6727-4ae2-a36d-0a26aae762df	5271fc4f-4383-41d4-a302-70be578956be	1	1	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
99857ffa-c851-435c-b969-6f5baa67732a	5271fc4f-4383-41d4-a302-70be578956be	1	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
bc895de8-be8d-4a7d-a611-a4c0b40ff208	5271fc4f-4383-41d4-a302-70be578956be	1	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
adbb48c4-f686-4454-86db-48ba5f1020aa	5271fc4f-4383-41d4-a302-70be578956be	1	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
5e5c226d-4962-4f35-bda4-1c774bde7e29	5271fc4f-4383-41d4-a302-70be578956be	1	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
37f5d2fb-b13f-4d36-b0ef-16436180931c	5271fc4f-4383-41d4-a302-70be578956be	2	1	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
f246d53a-5be7-416c-b432-c4a6083942ab	5271fc4f-4383-41d4-a302-70be578956be	2	2	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
c2232433-8c99-40cd-843f-10e7c2d1062a	5271fc4f-4383-41d4-a302-70be578956be	2	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
0409c6a6-1b5e-40b0-af81-d4a8523cd7ff	5271fc4f-4383-41d4-a302-70be578956be	2	4	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
97ddfd52-481a-46eb-a0a3-fc1bee1fd9ba	5271fc4f-4383-41d4-a302-70be578956be	2	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
a465397c-7005-4ddc-80b4-2d07bbc8bfb7	5271fc4f-4383-41d4-a302-70be578956be	3	1	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
dcdc815f-aac7-4011-bac0-8d9940318347	5271fc4f-4383-41d4-a302-70be578956be	3	2	0.062	339dee6f-1d8f-482c-8465-a87d2650af5e
1bcfbb0c-29e3-4be7-ae3f-ba04fe898bda	5271fc4f-4383-41d4-a302-70be578956be	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1de4ecde-7269-4b7f-9120-2353d08f7d86	5271fc4f-4383-41d4-a302-70be578956be	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5d94a629-b216-42d8-9736-0358ae02d204	5271fc4f-4383-41d4-a302-70be578956be	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1f5357e0-dfc8-4a6e-acad-2bc2e1bc0d35	5271fc4f-4383-41d4-a302-70be578956be	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
27969e5a-a1d2-410d-9cd5-d8f4481ee82a	5271fc4f-4383-41d4-a302-70be578956be	4	2	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
c6cc7dfc-6017-42d6-8502-d3cc792e94b1	5271fc4f-4383-41d4-a302-70be578956be	4	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
05b9609a-e0c6-4362-8b6c-786df8fb8b21	5271fc4f-4383-41d4-a302-70be578956be	4	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
326d1c24-7495-47cc-a5ee-c24b3710beb5	5271fc4f-4383-41d4-a302-70be578956be	4	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
dbce3fef-dcb7-41cd-89d2-bf4011203cca	5271fc4f-4383-41d4-a302-70be578956be	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
250ff474-63bc-46ec-bcc6-a307147ab850	5271fc4f-4383-41d4-a302-70be578956be	5	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
56978061-8679-4b86-b549-0361d66d75c0	5271fc4f-4383-41d4-a302-70be578956be	5	3	0.800	339dee6f-1d8f-482c-8465-a87d2650af5e
d265a373-434d-4833-9cc5-5ca4bb8ed4c1	5271fc4f-4383-41d4-a302-70be578956be	5	4	0.800	339dee6f-1d8f-482c-8465-a87d2650af5e
0ea826c3-6fad-4447-a9ec-92601741d860	5271fc4f-4383-41d4-a302-70be578956be	5	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
6cf3cbef-800e-4a8a-ac0d-64ca73f2ec02	5271fc4f-4383-41d4-a302-70be578956be	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ae9cc66a-a6d1-4e5c-bb87-b7c55ed57289	5271fc4f-4383-41d4-a302-70be578956be	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0b71dc4-224f-4619-91ea-49e8a74bc272	5271fc4f-4383-41d4-a302-70be578956be	6	3	0.338	339dee6f-1d8f-482c-8465-a87d2650af5e
0729798e-2fe8-4159-8f7b-2036bdbd1132	5271fc4f-4383-41d4-a302-70be578956be	6	4	0.624	339dee6f-1d8f-482c-8465-a87d2650af5e
903e9372-028d-4fd3-9189-3a5a86fefc14	5271fc4f-4383-41d4-a302-70be578956be	6	5	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
4293c416-1e95-4f52-93ea-740b6b7bb1f1	5271fc4f-4383-41d4-a302-70be578956be	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3a658e42-a9a3-4dd1-926b-25231b092938	5271fc4f-4383-41d4-a302-70be578956be	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
100652ae-27e6-49a6-ae2b-e578b389ac45	5271fc4f-4383-41d4-a302-70be578956be	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d8fb0b1e-6a6e-4164-9c7e-4a8ff965f8e4	5271fc4f-4383-41d4-a302-70be578956be	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6afc3c58-d5fa-46f2-a0d1-38f16a3f07a5	5271fc4f-4383-41d4-a302-70be578956be	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ee5665c1-b2e0-48cd-b846-f65e7758d31b	5271fc4f-4383-41d4-a302-70be578956be	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bc8d924f-e37d-4cb8-924a-163f28e7d325	5271fc4f-4383-41d4-a302-70be578956be	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
24ee573f-dab7-4ac9-8151-96a381f8bc37	5271fc4f-4383-41d4-a302-70be578956be	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
50b56ac6-a0a5-4a99-b9c2-3bc99304a464	5271fc4f-4383-41d4-a302-70be578956be	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cb60e896-1cb7-4e86-8694-f8ac80186a3c	5271fc4f-4383-41d4-a302-70be578956be	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
02fc9a58-4f70-4dd5-8708-89f3fe44b913	5271fc4f-4383-41d4-a302-70be578956be	9	1	0.156	339dee6f-1d8f-482c-8465-a87d2650af5e
c6b6c5bb-8dea-45a8-9aa0-22b9dcd2d4a5	5271fc4f-4383-41d4-a302-70be578956be	9	2	0.260	339dee6f-1d8f-482c-8465-a87d2650af5e
af85ee54-9d6e-48c9-bc7a-296f5a9c9e73	5271fc4f-4383-41d4-a302-70be578956be	9	3	0.520	339dee6f-1d8f-482c-8465-a87d2650af5e
b6581244-6e4c-4e22-9165-ca379a2962e0	5271fc4f-4383-41d4-a302-70be578956be	9	4	0.208	339dee6f-1d8f-482c-8465-a87d2650af5e
2e4ba990-a16e-4230-b0e8-3baedd5d5dce	5271fc4f-4383-41d4-a302-70be578956be	9	5	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
c3326a2e-597f-40af-8688-a394eef697f0	5271fc4f-4383-41d4-a302-70be578956be	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdca4071-0454-4202-8817-c0829ed31641	5271fc4f-4383-41d4-a302-70be578956be	10	2	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
5f5f71fd-1c40-4376-a024-e07f0141932c	5271fc4f-4383-41d4-a302-70be578956be	10	3	0.208	339dee6f-1d8f-482c-8465-a87d2650af5e
b24784ee-4481-42e5-866b-fae83f94d066	5271fc4f-4383-41d4-a302-70be578956be	10	4	0.208	339dee6f-1d8f-482c-8465-a87d2650af5e
32599c55-22af-43f8-b046-46fb3886c5bf	5271fc4f-4383-41d4-a302-70be578956be	10	5	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
b43a8ef3-5157-426e-b7bc-b818f53bfb03	5271fc4f-4383-41d4-a302-70be578956be	11	1	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
89b6b796-e0b2-4e13-a939-92ec9dd7ace4	5271fc4f-4383-41d4-a302-70be578956be	11	2	0.160	339dee6f-1d8f-482c-8465-a87d2650af5e
5762cbcd-099d-45a4-9710-d4d59932f03c	5271fc4f-4383-41d4-a302-70be578956be	11	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
d36b8cb0-5f6a-4925-9343-9c537aa65c9e	5271fc4f-4383-41d4-a302-70be578956be	11	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
dfc9400a-79a2-490c-b5c9-dc6d9cec89c1	5271fc4f-4383-41d4-a302-70be578956be	11	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
c9b86817-d1c8-4811-b997-f88dd23689ed	5271fc4f-4383-41d4-a302-70be578956be	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7b67a30e-3b4f-4d3f-97a4-8d1b4c63494e	5271fc4f-4383-41d4-a302-70be578956be	12	2	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
72028baa-ffdc-4fd2-8dea-b8be87525a02	5271fc4f-4383-41d4-a302-70be578956be	12	3	0.416	339dee6f-1d8f-482c-8465-a87d2650af5e
5b901d1e-097d-4e63-8e53-85cc67c9f1df	5271fc4f-4383-41d4-a302-70be578956be	12	4	0.416	339dee6f-1d8f-482c-8465-a87d2650af5e
235e3555-b5ce-48f8-938e-6e1c47f2eddd	5271fc4f-4383-41d4-a302-70be578956be	12	5	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
ed30797a-2188-4391-b784-acbb72078a84	5271fc4f-4383-41d4-a302-70be578956be	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
030f46a0-50c7-48e6-8af2-84c05c61e14d	5271fc4f-4383-41d4-a302-70be578956be	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c0bd4d56-ae1a-4323-9232-2102199a444c	5271fc4f-4383-41d4-a302-70be578956be	13	3	0.312	339dee6f-1d8f-482c-8465-a87d2650af5e
ca430ba7-1baa-4997-a882-35bce0346e13	5271fc4f-4383-41d4-a302-70be578956be	13	4	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
95367e05-7d2d-4a37-a9ff-6e3e729fe9ba	5271fc4f-4383-41d4-a302-70be578956be	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
309ce4a4-b2fb-4554-a2e1-fc0e39900465	5271fc4f-4383-41d4-a302-70be578956be	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
df9f9237-d02a-491a-8e6c-7ff236fb7a60	5271fc4f-4383-41d4-a302-70be578956be	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ef509631-15b1-4083-9e00-e9370fbc2ae5	5271fc4f-4383-41d4-a302-70be578956be	14	3	0.039	339dee6f-1d8f-482c-8465-a87d2650af5e
d03c55df-183e-40c8-a26b-3edaef7f7676	5271fc4f-4383-41d4-a302-70be578956be	14	4	0.039	339dee6f-1d8f-482c-8465-a87d2650af5e
cb0a6522-16ab-41a0-b682-95f61143eec7	5271fc4f-4383-41d4-a302-70be578956be	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
34af8678-ebfd-44a4-b024-727678e0f1e6	5271fc4f-4383-41d4-a302-70be578956be	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
07c785a3-45dc-40ff-b26d-c03a899108ac	5271fc4f-4383-41d4-a302-70be578956be	15	2	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
99dfad84-a3f3-4199-80d8-8c6efac7fe9d	5271fc4f-4383-41d4-a302-70be578956be	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
33f751ba-5abd-4a8d-aee5-dd9769474009	5271fc4f-4383-41d4-a302-70be578956be	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aa64171e-567f-438d-9b1b-2d10aec6c7ab	5271fc4f-4383-41d4-a302-70be578956be	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dac6f9c5-09da-4df0-80a4-7d3353e4ae70	5271fc4f-4383-41d4-a302-70be578956be	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
71465ad3-726a-41eb-97c2-784234adc56e	5271fc4f-4383-41d4-a302-70be578956be	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
421a95a0-ca0f-4f7c-8106-96b8cea2acff	5271fc4f-4383-41d4-a302-70be578956be	16	3	0.062	339dee6f-1d8f-482c-8465-a87d2650af5e
367a27a2-673f-4b1f-81e3-c53a3192432d	5271fc4f-4383-41d4-a302-70be578956be	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e16329d8-fa42-4f12-a046-0fc114b75034	5271fc4f-4383-41d4-a302-70be578956be	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5cb86e7f-8a13-488e-978c-979246160ba7	5271fc4f-4383-41d4-a302-70be578956be	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ec10414c-53e0-4d88-8171-20043176b58b	5271fc4f-4383-41d4-a302-70be578956be	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
110834c2-9f5d-4386-9c61-e217a6d72fa1	5271fc4f-4383-41d4-a302-70be578956be	17	3	0.078	339dee6f-1d8f-482c-8465-a87d2650af5e
f0f01672-92fc-41d9-92da-7538e7fec180	5271fc4f-4383-41d4-a302-70be578956be	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
be39ea82-4ded-40c9-ab3f-b005354503b1	5271fc4f-4383-41d4-a302-70be578956be	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
93cd41bd-b89a-4458-bdd9-b9e0cf18db9e	5271fc4f-4383-41d4-a302-70be578956be	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
29321ba1-e24d-4af5-a609-02aa28219e44	5271fc4f-4383-41d4-a302-70be578956be	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b5178ea-db37-442a-9158-b9a0ad0f44ea	5271fc4f-4383-41d4-a302-70be578956be	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4a049658-f8c4-4745-a8c4-f1857740c2e1	5271fc4f-4383-41d4-a302-70be578956be	18	4	0.078	339dee6f-1d8f-482c-8465-a87d2650af5e
d0bf8adc-0af9-45c5-a860-816bcc7b0430	5271fc4f-4383-41d4-a302-70be578956be	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fef049fd-4ca6-41e0-9163-4871e69da282	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	1	1	0.234	339dee6f-1d8f-482c-8465-a87d2650af5e
2e4f119a-e4c6-435f-903c-066e341ca628	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	1	2	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
379e1ce7-b14d-4db3-ab81-5d097c7bc6c6	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	1	3	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
9364f744-658f-4fc5-bfe9-df1f2534aefa	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	1	4	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
441f7cba-4320-407e-8dc9-05421fd09f26	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	1	5	0.117	339dee6f-1d8f-482c-8465-a87d2650af5e
66334890-770a-48f9-a199-62717b94f418	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	1	0.234	339dee6f-1d8f-482c-8465-a87d2650af5e
3bc6cbeb-81ed-4c8e-8d44-725f4d77be87	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	2	0.351	339dee6f-1d8f-482c-8465-a87d2650af5e
dc2b432f-3f3b-4cc4-8ced-571421be7c35	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	3	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
6f8afbe0-d8c1-4a8c-9ef9-a513bcbc0638	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	4	0.351	339dee6f-1d8f-482c-8465-a87d2650af5e
144f00fe-6406-493b-8e82-6fc68b66bc01	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	5	0.117	339dee6f-1d8f-482c-8465-a87d2650af5e
a958b170-8753-4f3d-87f5-f381585fd72c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	1	0.063	339dee6f-1d8f-482c-8465-a87d2650af5e
6a4d735e-37fa-48f7-a7c1-f798b48951c2	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	2	0.076	339dee6f-1d8f-482c-8465-a87d2650af5e
4dea4429-4e0a-4ba3-bf6e-859925a39a0a	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f7c7f899-cef5-442e-94d2-f46df79c81c4	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
be52788a-b1e1-4183-9487-ba6d2a812ee2	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ff0d80b6-9bb3-43e1-b437-95ff99b302d8	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b72c06b4-f5f5-47f1-b3e3-e3261112a933	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	2	0.234	339dee6f-1d8f-482c-8465-a87d2650af5e
78a921c7-5491-48d7-bb96-bbdb7a26fa44	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	3	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
860fbc1e-85b5-420c-8afb-84a1e37905a5	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	4	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
2984164e-4663-4365-8bf0-448af0f83398	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	5	0.117	339dee6f-1d8f-482c-8465-a87d2650af5e
18d7a4c3-746a-4ab2-954d-706e5b63a842	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
910b5c34-a0b4-41fe-876e-cefe0c078a23	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	2	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
b2745f38-aa3a-48bb-9996-1219d9a0d3aa	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	3	0.937	339dee6f-1d8f-482c-8465-a87d2650af5e
4f05cd4b-c676-4486-afd5-79dcb2b748bb	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	4	0.937	339dee6f-1d8f-482c-8465-a87d2650af5e
aad815fd-aa80-44da-940c-3a97c9064506	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	5	0.117	339dee6f-1d8f-482c-8465-a87d2650af5e
421ae8be-7541-41c8-ab4e-a53cb174e1ba	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4250ce50-095f-47ad-889f-aec61063fa1b	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
17323e22-33ac-42ae-b737-0901477c3f83	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	6	3	0.411	339dee6f-1d8f-482c-8465-a87d2650af5e
539f77b6-5521-475e-b76b-c80afdcc1053	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	6	4	0.759	339dee6f-1d8f-482c-8465-a87d2650af5e
b64db881-bba4-4d21-b718-17585ee2157b	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	6	5	0.063	339dee6f-1d8f-482c-8465-a87d2650af5e
e80f2cbd-b529-4026-a5c9-badebc76451c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0d6bbb6-ed7f-4899-8ccd-ee4a3ecf2d00	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4573b801-772a-4948-be2c-9069576b22e5	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6d40b527-4f1e-4f48-a269-02f234df916a	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3464f750-a226-4d30-b965-cdf5e393d28c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a2058333-af0e-4545-9cab-5990ed5642b2	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
db333219-b98d-4bac-afe2-ffd91af7ebb8	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
207fe288-3faa-4787-be08-9cf903c39172	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
28db600c-5e18-4774-842b-3be682062131	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3728bdb5-d2b4-4403-922b-f798df2a710a	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ab9fe655-7a24-4ea3-ba76-73779eab9d3a	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	9	1	0.190	339dee6f-1d8f-482c-8465-a87d2650af5e
f162031d-9d48-4f99-8a84-cf2d8dfbaabc	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	9	2	0.316	339dee6f-1d8f-482c-8465-a87d2650af5e
b29c2b76-db61-4a71-91d3-1493d854c7a1	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	9	3	0.633	339dee6f-1d8f-482c-8465-a87d2650af5e
9ef559b0-caee-4176-9e67-09b6ffe585ff	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	9	4	0.253	339dee6f-1d8f-482c-8465-a87d2650af5e
32145954-663e-4c23-b406-79f7530b5def	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	9	5	0.127	339dee6f-1d8f-482c-8465-a87d2650af5e
aa27d8c2-db22-4c60-98f0-679507b767e3	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
324ff9eb-e84b-4906-9d18-3f5ce61fe8ac	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	10	2	0.127	339dee6f-1d8f-482c-8465-a87d2650af5e
b209545e-66ff-4c12-9448-0fc8ab1db98b	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	10	3	0.253	339dee6f-1d8f-482c-8465-a87d2650af5e
7000caa8-362e-4f8f-bbbe-db943d96bc6d	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	10	4	0.253	339dee6f-1d8f-482c-8465-a87d2650af5e
d5ee7814-3feb-4d1a-b566-c1c3c4cb7570	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	10	5	0.063	339dee6f-1d8f-482c-8465-a87d2650af5e
c20a476f-94eb-472c-acc1-7d5e0b561453	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	11	1	0.117	339dee6f-1d8f-482c-8465-a87d2650af5e
66b41be3-2443-4801-9d6f-73b31893b27f	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	11	2	0.187	339dee6f-1d8f-482c-8465-a87d2650af5e
8ee90cb2-1c00-4dd1-9ae7-e0f183d6e9c3	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	11	3	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
1e36ed55-bf94-4091-9940-da5f4d78e822	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	11	4	0.469	339dee6f-1d8f-482c-8465-a87d2650af5e
a71c9452-f160-457e-a0c0-a6bf60761eba	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	11	5	0.117	339dee6f-1d8f-482c-8465-a87d2650af5e
75845858-576c-4aa5-acfd-54f5eee8285c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
28e3be5e-9ef3-4d7f-9b24-480ad71e685f	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	12	2	0.127	339dee6f-1d8f-482c-8465-a87d2650af5e
f9d7b35a-c5e1-4a6a-8f8a-83c94ccbc02a	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	12	3	0.506	339dee6f-1d8f-482c-8465-a87d2650af5e
5fe9c0d4-ddbb-4ccb-ac25-5f402a252677	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	12	4	0.506	339dee6f-1d8f-482c-8465-a87d2650af5e
4c5b43d9-3cec-445a-92ee-f870e55d3e31	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	12	5	0.079	339dee6f-1d8f-482c-8465-a87d2650af5e
02802451-5b4f-47ec-9cea-6f37daefabd8	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d819166b-f2d6-4a94-85f3-81d83be23cb3	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c694896c-c6d6-499e-bc5e-71da634b657c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	13	3	0.380	339dee6f-1d8f-482c-8465-a87d2650af5e
d8b2580f-847d-43c0-8422-66da21d0fc6e	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	13	4	0.455	339dee6f-1d8f-482c-8465-a87d2650af5e
4fd879ad-1198-49c9-a7b2-77cfc568dd25	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a7ddcc8e-2254-4187-af50-9d2d4bccbf19	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
366a6f3b-fb5c-440e-8a9b-ba354c2bfe05	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ce2ab56b-3cf7-4e0c-9308-a65d198f642b	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	14	3	0.047	339dee6f-1d8f-482c-8465-a87d2650af5e
756f2df1-2dd6-4dcd-b532-dc412fe7a775	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	14	4	0.047	339dee6f-1d8f-482c-8465-a87d2650af5e
b12cf49f-9f18-466c-bd28-fc44ce968a19	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d0554ce4-80cb-4254-8e88-9f7d76dea965	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4d32d646-beb8-4f1d-ae55-94192694a96c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	15	2	0.127	339dee6f-1d8f-482c-8465-a87d2650af5e
e988330c-6c49-4140-8eaf-a75c773695f2	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
21c6fbf3-d240-48bb-a3ff-19d0bbda406e	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5dc7d698-24c3-4ea7-83dd-22a617e0abe3	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
65342a38-2d4a-4898-8d32-62838f70fcfe	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
251b9faa-e8ec-4386-b475-a299e1f319d5	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2271bd4e-81f7-4515-8cc7-4a927b7e0cdf	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	16	3	0.076	339dee6f-1d8f-482c-8465-a87d2650af5e
26a16c79-1406-4dfc-ad9d-cf7bf0644534	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e9b7e763-5989-4034-a5c5-e10e03c07cd7	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cf1fefd9-835e-4f2b-8035-a797df4732e2	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
35c98dc6-5245-4147-bac9-9c7545a264fb	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
366ce223-bb72-4308-83a5-e7af25de074f	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	17	3	0.095	339dee6f-1d8f-482c-8465-a87d2650af5e
45c94839-0c52-4a2f-b035-835b71ab0d44	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b7b5236c-a924-43f5-bd98-6de00ce8c414	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
70870bc7-95c8-4f30-90f7-71949332fd7c	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3c5490ba-84e7-41bc-916c-71ee9312f3e6	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
91a13340-61df-493d-b44e-9dd2a318ea08	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
856929d4-465a-4cb4-8007-271d8ceefb87	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	18	4	0.095	339dee6f-1d8f-482c-8465-a87d2650af5e
6cccc09e-fee3-4f6e-9bd4-ccc858133c65	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f63d1108-ea53-4e07-95dd-3c727cc1cfcb	17522252-395a-48b6-a72d-f4e3db3df2b4	1	1	0.249	339dee6f-1d8f-482c-8465-a87d2650af5e
24a4414c-ea77-4c15-9afb-bf5ba997c188	17522252-395a-48b6-a72d-f4e3db3df2b4	1	2	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
58ace6c4-67b6-4314-81b3-2df7d05acd6d	17522252-395a-48b6-a72d-f4e3db3df2b4	1	3	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
f711e69d-0902-4863-afdb-27b95db4f050	17522252-395a-48b6-a72d-f4e3db3df2b4	1	4	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
f24b9376-dce6-4ff2-a49f-96b164b58eaa	17522252-395a-48b6-a72d-f4e3db3df2b4	1	5	0.124	339dee6f-1d8f-482c-8465-a87d2650af5e
9953eb0f-cec7-4de1-ae4f-15a33be5f84a	17522252-395a-48b6-a72d-f4e3db3df2b4	2	1	0.249	339dee6f-1d8f-482c-8465-a87d2650af5e
79363c05-2490-42f4-9903-26a0e3c12625	17522252-395a-48b6-a72d-f4e3db3df2b4	2	2	0.373	339dee6f-1d8f-482c-8465-a87d2650af5e
e4ef101a-75cf-4920-a0a1-85562382dae9	17522252-395a-48b6-a72d-f4e3db3df2b4	2	3	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
08091fdf-fbe0-44d7-825b-85d3d557d021	17522252-395a-48b6-a72d-f4e3db3df2b4	2	4	0.373	339dee6f-1d8f-482c-8465-a87d2650af5e
9aad0f26-65f1-42a8-a346-963016705e78	17522252-395a-48b6-a72d-f4e3db3df2b4	2	5	0.124	339dee6f-1d8f-482c-8465-a87d2650af5e
f680440b-feb6-4e65-8ca1-d0a8aa00185b	17522252-395a-48b6-a72d-f4e3db3df2b4	3	1	0.069	339dee6f-1d8f-482c-8465-a87d2650af5e
4d0db74b-93e7-430a-8ac3-d6bb8acc99b1	17522252-395a-48b6-a72d-f4e3db3df2b4	3	2	0.082	339dee6f-1d8f-482c-8465-a87d2650af5e
2b280dcf-1cc3-4a2a-89c1-2ed32f69a554	17522252-395a-48b6-a72d-f4e3db3df2b4	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
716627e7-4836-4874-a985-3233d14a1628	17522252-395a-48b6-a72d-f4e3db3df2b4	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c558daf8-45a1-43aa-bf85-dcdadc37a1a2	17522252-395a-48b6-a72d-f4e3db3df2b4	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
14702e7f-8017-4bbf-bd13-8af7fa34526c	17522252-395a-48b6-a72d-f4e3db3df2b4	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
791282e5-dc5b-4d4d-9ec3-11251c03b10b	17522252-395a-48b6-a72d-f4e3db3df2b4	4	2	0.249	339dee6f-1d8f-482c-8465-a87d2650af5e
5f1d3cd7-cfc8-4fb0-afd6-ea073afafef1	17522252-395a-48b6-a72d-f4e3db3df2b4	4	3	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
42196164-8e3d-4645-8f24-5d4380e01322	17522252-395a-48b6-a72d-f4e3db3df2b4	4	4	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
b09c8a38-cfe3-435d-84d5-7cfc8fad38c8	17522252-395a-48b6-a72d-f4e3db3df2b4	4	5	0.124	339dee6f-1d8f-482c-8465-a87d2650af5e
84262894-1bdd-42e6-a5ce-7708e048ad8d	17522252-395a-48b6-a72d-f4e3db3df2b4	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
723d4e2d-3926-427b-9d3f-04774f519db1	17522252-395a-48b6-a72d-f4e3db3df2b4	5	2	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
9eb82949-9ac0-40d0-ae79-1cc4c81a0e0e	17522252-395a-48b6-a72d-f4e3db3df2b4	5	3	0.995	339dee6f-1d8f-482c-8465-a87d2650af5e
85ff14f6-e555-4016-80d5-23ce3d26da2e	17522252-395a-48b6-a72d-f4e3db3df2b4	5	4	0.995	339dee6f-1d8f-482c-8465-a87d2650af5e
27276f8c-ef41-4967-90a0-983063af95d0	17522252-395a-48b6-a72d-f4e3db3df2b4	5	5	0.124	339dee6f-1d8f-482c-8465-a87d2650af5e
79797605-247a-4336-8c3e-fd93ba4f0ded	17522252-395a-48b6-a72d-f4e3db3df2b4	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
24d11f88-286c-42be-981e-46365b6e74f6	17522252-395a-48b6-a72d-f4e3db3df2b4	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
70fe1527-66f2-44c6-ac92-5b31e31e3f85	17522252-395a-48b6-a72d-f4e3db3df2b4	6	3	0.446	339dee6f-1d8f-482c-8465-a87d2650af5e
1575626c-f5a8-4f4c-afe7-1caf45458a62	17522252-395a-48b6-a72d-f4e3db3df2b4	6	4	0.824	339dee6f-1d8f-482c-8465-a87d2650af5e
50ae55c6-993a-4dec-a2ca-cfd826cdbbb0	17522252-395a-48b6-a72d-f4e3db3df2b4	6	5	0.069	339dee6f-1d8f-482c-8465-a87d2650af5e
5e1c0d52-c53c-4e34-9aaf-7485fcc5216a	17522252-395a-48b6-a72d-f4e3db3df2b4	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9d48fc75-359e-476e-aec1-4cd289f5a63a	17522252-395a-48b6-a72d-f4e3db3df2b4	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b12c8e8a-4cbd-4434-8c27-04d55c00f139	17522252-395a-48b6-a72d-f4e3db3df2b4	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
12947f18-a343-46ae-b256-a2f23a671c7f	17522252-395a-48b6-a72d-f4e3db3df2b4	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
17e90b07-1dc9-4275-9e33-2aaffa231471	17522252-395a-48b6-a72d-f4e3db3df2b4	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6ea936da-8e75-40ff-ab09-947f7e92b900	17522252-395a-48b6-a72d-f4e3db3df2b4	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
19d181c5-7c54-40d7-b3f2-92c47664817c	17522252-395a-48b6-a72d-f4e3db3df2b4	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d6dc2216-5a24-4799-a5b5-dabafd7cd2c1	17522252-395a-48b6-a72d-f4e3db3df2b4	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
392f19af-408e-49f7-8b2d-67094ac71da1	17522252-395a-48b6-a72d-f4e3db3df2b4	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
da73bdc5-cf12-41ab-a22f-1ae407c6365e	17522252-395a-48b6-a72d-f4e3db3df2b4	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f60fa38a-56e5-47ba-8a41-5406198a8baf	17522252-395a-48b6-a72d-f4e3db3df2b4	9	1	0.206	339dee6f-1d8f-482c-8465-a87d2650af5e
1b7ab735-a43f-4915-822c-65e252b21241	17522252-395a-48b6-a72d-f4e3db3df2b4	9	2	0.343	339dee6f-1d8f-482c-8465-a87d2650af5e
c2f14742-895d-427c-87ce-4335e2d43f39	17522252-395a-48b6-a72d-f4e3db3df2b4	9	3	0.687	339dee6f-1d8f-482c-8465-a87d2650af5e
74436e0c-801d-4fc7-a5bc-2e78676b710f	17522252-395a-48b6-a72d-f4e3db3df2b4	9	4	0.275	339dee6f-1d8f-482c-8465-a87d2650af5e
e497693d-8fa2-427a-8668-034b31f91883	17522252-395a-48b6-a72d-f4e3db3df2b4	9	5	0.137	339dee6f-1d8f-482c-8465-a87d2650af5e
17610ab2-6502-4376-bf26-d03a7637d09b	17522252-395a-48b6-a72d-f4e3db3df2b4	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8a8f402b-1861-4221-892d-42ccfdaa6784	17522252-395a-48b6-a72d-f4e3db3df2b4	10	2	0.137	339dee6f-1d8f-482c-8465-a87d2650af5e
ff836403-8218-4f17-a4c0-e7ff821c6cc7	17522252-395a-48b6-a72d-f4e3db3df2b4	10	3	0.275	339dee6f-1d8f-482c-8465-a87d2650af5e
efdbf2df-65a1-4cbb-8b38-263e3810b94d	17522252-395a-48b6-a72d-f4e3db3df2b4	10	4	0.275	339dee6f-1d8f-482c-8465-a87d2650af5e
7c8a49c5-4ff6-48e9-a4a8-47209e2d6e3c	17522252-395a-48b6-a72d-f4e3db3df2b4	10	5	0.069	339dee6f-1d8f-482c-8465-a87d2650af5e
c6a39e8a-1a2f-4569-ac62-88f05a52be86	17522252-395a-48b6-a72d-f4e3db3df2b4	11	1	0.124	339dee6f-1d8f-482c-8465-a87d2650af5e
f1b0f016-52c7-4e74-b3c6-deb6527dc553	17522252-395a-48b6-a72d-f4e3db3df2b4	11	2	0.199	339dee6f-1d8f-482c-8465-a87d2650af5e
a29f7865-f93d-4362-a210-207a5a9d0c46	17522252-395a-48b6-a72d-f4e3db3df2b4	11	3	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
79f95115-27af-4bc3-a55e-709b3d72c859	17522252-395a-48b6-a72d-f4e3db3df2b4	11	4	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
693a6a0a-7f9b-48a8-a46d-5c2f9d35f985	17522252-395a-48b6-a72d-f4e3db3df2b4	11	5	0.124	339dee6f-1d8f-482c-8465-a87d2650af5e
d718ad37-1c21-45d1-af02-37791197c718	17522252-395a-48b6-a72d-f4e3db3df2b4	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b716d3c1-efda-4dd4-ad98-6c0e828dca48	17522252-395a-48b6-a72d-f4e3db3df2b4	12	2	0.137	339dee6f-1d8f-482c-8465-a87d2650af5e
f90e992e-6609-4c2c-9d63-72e8ad451402	17522252-395a-48b6-a72d-f4e3db3df2b4	12	3	0.549	339dee6f-1d8f-482c-8465-a87d2650af5e
4bd92d1a-6f04-4840-8575-3e340ae49acc	17522252-395a-48b6-a72d-f4e3db3df2b4	12	4	0.549	339dee6f-1d8f-482c-8465-a87d2650af5e
fa8e52f0-eb6c-47c0-a6c5-9d8e0fca5b40	17522252-395a-48b6-a72d-f4e3db3df2b4	12	5	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
410ff76c-2f29-4d19-b362-e3bdd2daf19b	17522252-395a-48b6-a72d-f4e3db3df2b4	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7856557a-02dd-4c7e-8dba-71a00231f60d	17522252-395a-48b6-a72d-f4e3db3df2b4	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
35ce3839-5e20-48f4-b99a-5c780bfdaaa2	17522252-395a-48b6-a72d-f4e3db3df2b4	13	3	0.412	339dee6f-1d8f-482c-8465-a87d2650af5e
523b09d1-8c52-4ba2-8346-72d0aecc0b1b	17522252-395a-48b6-a72d-f4e3db3df2b4	13	4	0.494	339dee6f-1d8f-482c-8465-a87d2650af5e
55ac9cfe-65f7-41e2-855b-c0e2fff4a259	17522252-395a-48b6-a72d-f4e3db3df2b4	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2f4b8431-6104-4d05-af2d-71a383e9fa13	17522252-395a-48b6-a72d-f4e3db3df2b4	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4662628f-b5c6-4115-adf0-8fae9fdbb50d	17522252-395a-48b6-a72d-f4e3db3df2b4	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a42f0cb2-4746-4d91-b57d-0e25b4768b5f	17522252-395a-48b6-a72d-f4e3db3df2b4	14	3	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
b2a60743-651a-4f51-ac39-6d8447892852	17522252-395a-48b6-a72d-f4e3db3df2b4	14	4	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
7882983a-1de7-4c51-b95f-a976bb68bd79	17522252-395a-48b6-a72d-f4e3db3df2b4	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a0d23688-5836-4492-a6bd-e45ee8287662	17522252-395a-48b6-a72d-f4e3db3df2b4	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
223a40a4-30db-4f7e-a0a1-dbd8eb277886	17522252-395a-48b6-a72d-f4e3db3df2b4	15	2	0.137	339dee6f-1d8f-482c-8465-a87d2650af5e
b059c05a-5d6b-4e5f-8c6a-ffa15f615206	17522252-395a-48b6-a72d-f4e3db3df2b4	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8d06d70f-8746-4c9b-bdd0-cb2e5be6d0c2	17522252-395a-48b6-a72d-f4e3db3df2b4	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c0d66631-2a95-49a1-9a0e-75283e5b8694	17522252-395a-48b6-a72d-f4e3db3df2b4	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5fb46b97-213a-488b-956a-f0040a900e0b	17522252-395a-48b6-a72d-f4e3db3df2b4	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f3752dab-0963-4c0b-926f-a26688814fb0	17522252-395a-48b6-a72d-f4e3db3df2b4	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3309aa65-95b9-4df7-9c9e-d613a15802d3	17522252-395a-48b6-a72d-f4e3db3df2b4	16	3	0.082	339dee6f-1d8f-482c-8465-a87d2650af5e
efc48c32-2223-4999-a537-416a0e0fdd1e	17522252-395a-48b6-a72d-f4e3db3df2b4	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b9f4eafd-68d3-4d65-b554-3905afe88c4b	17522252-395a-48b6-a72d-f4e3db3df2b4	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63f70989-7ebe-41e6-a739-5e0a4052a9af	17522252-395a-48b6-a72d-f4e3db3df2b4	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f17ffff7-8683-4e5f-aa62-12c11273be31	17522252-395a-48b6-a72d-f4e3db3df2b4	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5a6ec2dc-61a7-4af4-8b99-ca93eb95aacd	17522252-395a-48b6-a72d-f4e3db3df2b4	17	3	0.103	339dee6f-1d8f-482c-8465-a87d2650af5e
a06c7a96-2015-4a7d-aed0-45e5090ab464	17522252-395a-48b6-a72d-f4e3db3df2b4	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b407a10d-e500-42e3-8da3-d57c45b39e56	17522252-395a-48b6-a72d-f4e3db3df2b4	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
89360efa-d0d6-4ef1-a841-bce9e80b6dda	17522252-395a-48b6-a72d-f4e3db3df2b4	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6df6c8ce-3b67-4360-a9a9-0aa07662223c	17522252-395a-48b6-a72d-f4e3db3df2b4	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bf620b12-ea51-49c3-9bf4-306b6b62bfff	17522252-395a-48b6-a72d-f4e3db3df2b4	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
03ce60ca-bd82-4df3-9b81-d383b2de7700	17522252-395a-48b6-a72d-f4e3db3df2b4	18	4	0.103	339dee6f-1d8f-482c-8465-a87d2650af5e
0ba84a81-f211-4543-9c2b-b197065437e2	17522252-395a-48b6-a72d-f4e3db3df2b4	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d8464ab2-9b25-41ff-a7ec-28a89978f5d9	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	1	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
40694314-9193-47cb-8af1-b6d3a428bcdf	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
5d3f5282-bd74-4255-8539-c5068bfdfed3	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
6a5ec95e-7eea-409c-b03f-56a191f6c2c2	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
d024591f-cbd8-4999-9351-851684a63de8	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
78b6d498-c966-473e-b36c-fb136ada8a2a	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	1	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
69b358e9-65cd-44ee-8a41-6acc2dceee66	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	2	0.563	339dee6f-1d8f-482c-8465-a87d2650af5e
b469ed6b-ee3a-4c6e-a869-2a63d0afc3e9	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
aaac6588-e1e6-4a6f-a536-253afa34c3be	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	4	0.563	339dee6f-1d8f-482c-8465-a87d2650af5e
17374a39-4f55-4c38-9e13-bea4cb1003cc	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
30f07834-7c55-4d28-a434-c48c4c8ad6e7	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	1	0.138	339dee6f-1d8f-482c-8465-a87d2650af5e
91913600-08c3-4611-9e33-f2928b95f2c5	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	2	0.166	339dee6f-1d8f-482c-8465-a87d2650af5e
bd1592e5-538b-44d7-9d04-8712c2f1f867	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
59523be1-c2db-449d-886f-eaa60e4536a8	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2fe52474-d2be-440f-b9f1-8d582c18f921	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e7e3ee2d-83c9-49dc-9a64-80e047fdc9d5	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
14d92d51-a51d-4a2b-9d24-e407c8041148	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	2	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
1d01aebe-cf17-4b62-80dc-629edbf32414	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
e00409e0-047a-4508-abdc-884c7c7fec3e	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
b150e0e5-1fe3-4b7d-aa31-7ced1659ccf7	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
c53c4a62-3ab7-4b2c-9b2e-80e427b7a9a1	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
feed6478-539f-43ae-a17c-0d1cdf25fc09	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
3c361158-27d2-496e-9fe7-6172b17a3889	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	3	1.500	339dee6f-1d8f-482c-8465-a87d2650af5e
48cd66d4-a576-474a-9df5-2f1685a22403	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	4	1.500	339dee6f-1d8f-482c-8465-a87d2650af5e
15735b79-214f-4fb9-8827-6ef8b8ef8a08	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
5308717d-0eab-4f58-9fa8-2999406c8a10	fa18eb5b-c301-4e26-93a1-021d57c20c2e	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4b2198b7-b822-4f4a-a92e-970078ff8889	fa18eb5b-c301-4e26-93a1-021d57c20c2e	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0677496-a9e2-4c4c-b076-dcbf281fc81c	fa18eb5b-c301-4e26-93a1-021d57c20c2e	6	3	0.897	339dee6f-1d8f-482c-8465-a87d2650af5e
77d9270a-dae0-4ef5-b051-ca9b27b9eb5b	fa18eb5b-c301-4e26-93a1-021d57c20c2e	6	4	1.656	339dee6f-1d8f-482c-8465-a87d2650af5e
c404eec3-b611-4388-93cd-4c40b81731a4	fa18eb5b-c301-4e26-93a1-021d57c20c2e	6	5	0.138	339dee6f-1d8f-482c-8465-a87d2650af5e
67146354-aaa3-4047-a09a-8ca2d6c6f4d3	fa18eb5b-c301-4e26-93a1-021d57c20c2e	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7102b0b3-e4c4-4aba-b89f-b668d1ec7248	fa18eb5b-c301-4e26-93a1-021d57c20c2e	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cf35ff2-0d0a-4b2c-a3c2-1809dcb113ac	fa18eb5b-c301-4e26-93a1-021d57c20c2e	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3ec598c4-28b8-4532-a7d7-ad3d59ccf191	fa18eb5b-c301-4e26-93a1-021d57c20c2e	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9c71f7b4-3f05-4432-8430-768a37c4abe7	fa18eb5b-c301-4e26-93a1-021d57c20c2e	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bb4f4478-e10e-4f5c-a086-e88cc1db349e	fa18eb5b-c301-4e26-93a1-021d57c20c2e	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
77b2dfb2-0c1d-4e5c-b8a6-1283d0ce9efa	fa18eb5b-c301-4e26-93a1-021d57c20c2e	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74862657-06c3-4d9e-9d57-28a75e8bdd5e	fa18eb5b-c301-4e26-93a1-021d57c20c2e	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3f4a44bf-a539-45a6-8dd5-4fe8ed2adeef	fa18eb5b-c301-4e26-93a1-021d57c20c2e	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2d8b4fe3-64f9-48d4-8c98-a30c893f3fdf	fa18eb5b-c301-4e26-93a1-021d57c20c2e	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
07656c25-5d08-474d-88fc-b037ad79105c	fa18eb5b-c301-4e26-93a1-021d57c20c2e	9	1	0.414	339dee6f-1d8f-482c-8465-a87d2650af5e
7e92b147-39ed-4aec-bece-8ad1d76e1dd8	fa18eb5b-c301-4e26-93a1-021d57c20c2e	9	2	0.690	339dee6f-1d8f-482c-8465-a87d2650af5e
cb62e405-3b30-40b5-ac87-9371877f2c58	fa18eb5b-c301-4e26-93a1-021d57c20c2e	9	3	1.380	339dee6f-1d8f-482c-8465-a87d2650af5e
c6c4a36a-28e6-45b1-9fca-777df8f10cde	fa18eb5b-c301-4e26-93a1-021d57c20c2e	9	4	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
8f424600-6943-4078-b099-efc843dd265c	fa18eb5b-c301-4e26-93a1-021d57c20c2e	9	5	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
0ed6c758-9a2e-4faa-a361-807a104c6e8f	fa18eb5b-c301-4e26-93a1-021d57c20c2e	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d42374c9-78bc-4f70-9a3f-7788caaa7aa3	fa18eb5b-c301-4e26-93a1-021d57c20c2e	10	2	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
b7366ab4-c8d3-47f9-bfe9-a0d6b2c875de	fa18eb5b-c301-4e26-93a1-021d57c20c2e	10	3	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
6cf7dc37-b697-4eee-8a86-793ee2b0fa33	fa18eb5b-c301-4e26-93a1-021d57c20c2e	10	4	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
a91fbc19-0bde-4b24-b211-22668b1db6ec	fa18eb5b-c301-4e26-93a1-021d57c20c2e	10	5	0.138	339dee6f-1d8f-482c-8465-a87d2650af5e
dae972ad-4426-4cb1-9241-9ef772be76fb	fa18eb5b-c301-4e26-93a1-021d57c20c2e	11	1	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
3889ba1b-bf8a-4d97-9623-412674054a8a	fa18eb5b-c301-4e26-93a1-021d57c20c2e	11	2	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
74ddc125-73c8-4ce6-9906-e4cb2b7016d2	fa18eb5b-c301-4e26-93a1-021d57c20c2e	11	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
a1cc6760-d1a3-4eb6-b5b7-43331adcfd71	fa18eb5b-c301-4e26-93a1-021d57c20c2e	11	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
c26c6be5-f2be-4df8-ad63-23ba85e35ae9	fa18eb5b-c301-4e26-93a1-021d57c20c2e	11	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
93eb72ad-9790-4857-8cb3-e936caf7ea9d	fa18eb5b-c301-4e26-93a1-021d57c20c2e	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ca2754b2-4dec-45b9-9eaf-9ab8b9c349be	fa18eb5b-c301-4e26-93a1-021d57c20c2e	12	2	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
3eba75db-1e74-45dd-9c64-e1365ffec806	fa18eb5b-c301-4e26-93a1-021d57c20c2e	12	3	1.104	339dee6f-1d8f-482c-8465-a87d2650af5e
dc0e694f-615c-4eef-943f-a52616953dc5	fa18eb5b-c301-4e26-93a1-021d57c20c2e	12	4	1.104	339dee6f-1d8f-482c-8465-a87d2650af5e
be2b98ea-9dc8-4389-8852-bdb0dc8eb7cb	fa18eb5b-c301-4e26-93a1-021d57c20c2e	12	5	0.173	339dee6f-1d8f-482c-8465-a87d2650af5e
6fb983b9-2e8a-48d0-bf27-1905bc9d900a	fa18eb5b-c301-4e26-93a1-021d57c20c2e	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c8c7af37-4a61-4ddd-8a57-38280cfc6662	fa18eb5b-c301-4e26-93a1-021d57c20c2e	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7995d5c2-25f3-4a7c-a141-ca6fc83f7fb2	fa18eb5b-c301-4e26-93a1-021d57c20c2e	13	3	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
6523a163-feb2-410a-b6ba-d508e1d8057a	fa18eb5b-c301-4e26-93a1-021d57c20c2e	13	4	0.994	339dee6f-1d8f-482c-8465-a87d2650af5e
cdf2d111-2b43-412a-80ae-21161116caad	fa18eb5b-c301-4e26-93a1-021d57c20c2e	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c4fee70b-896c-4d29-bcbe-8f684a3d5f67	fa18eb5b-c301-4e26-93a1-021d57c20c2e	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3dc42b0a-277a-49ae-9b9a-35e59bf3d3f1	fa18eb5b-c301-4e26-93a1-021d57c20c2e	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
90d28ddb-20d0-40e3-a045-ba04c3df0289	fa18eb5b-c301-4e26-93a1-021d57c20c2e	14	3	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
ddcd81aa-60ce-4bbb-92e3-daca422ecbca	fa18eb5b-c301-4e26-93a1-021d57c20c2e	14	4	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
4f70a33c-6df5-46a3-bd0d-d3154c658285	fa18eb5b-c301-4e26-93a1-021d57c20c2e	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7626f466-6eb8-4846-b42e-691f8a012ffc	fa18eb5b-c301-4e26-93a1-021d57c20c2e	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ff010535-4973-4d95-b0fa-6b326dd3f094	fa18eb5b-c301-4e26-93a1-021d57c20c2e	15	2	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
ea8c4174-aeb9-4cc9-ae22-85d7fd91dc11	fa18eb5b-c301-4e26-93a1-021d57c20c2e	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32fa889b-4e34-435e-843b-6af0931b7feb	fa18eb5b-c301-4e26-93a1-021d57c20c2e	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
36d97176-0d20-4b10-9698-b82055ab7d64	fa18eb5b-c301-4e26-93a1-021d57c20c2e	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
caf7df81-4cf7-4a55-beda-88847170c6df	fa18eb5b-c301-4e26-93a1-021d57c20c2e	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8e97690f-70c3-45e6-aa7c-7230fedba79c	fa18eb5b-c301-4e26-93a1-021d57c20c2e	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3eced5b9-892a-41c8-bd81-bb95710371f5	fa18eb5b-c301-4e26-93a1-021d57c20c2e	16	3	0.166	339dee6f-1d8f-482c-8465-a87d2650af5e
945cb226-d8e8-4d15-a759-daeaf69185bb	fa18eb5b-c301-4e26-93a1-021d57c20c2e	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0043f639-7665-4052-9164-f5f4d19342c3	fa18eb5b-c301-4e26-93a1-021d57c20c2e	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
44f06233-a462-4e0b-a8eb-add10ce7c5bc	fa18eb5b-c301-4e26-93a1-021d57c20c2e	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f82c7596-1909-4115-add5-29c2f91c3fce	fa18eb5b-c301-4e26-93a1-021d57c20c2e	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c14a73c0-bb6f-49eb-aab6-f6514f2654ff	fa18eb5b-c301-4e26-93a1-021d57c20c2e	17	3	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
5fb90aee-abac-4d30-8a08-2e62bc1f18de	fa18eb5b-c301-4e26-93a1-021d57c20c2e	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0aba8bb6-b366-4899-95c6-92b212ea7243	fa18eb5b-c301-4e26-93a1-021d57c20c2e	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
19a6ca01-596f-4068-8d57-3b9868e9f40d	fa18eb5b-c301-4e26-93a1-021d57c20c2e	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
adbf7830-e91f-4805-952d-3fb679cac1df	fa18eb5b-c301-4e26-93a1-021d57c20c2e	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
07387af3-ad54-4124-8c36-912f6ca4787e	fa18eb5b-c301-4e26-93a1-021d57c20c2e	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
03848320-d869-4022-a918-23cc3a0219f0	fa18eb5b-c301-4e26-93a1-021d57c20c2e	18	4	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
ab8123b5-3133-4828-82e1-fd8b07ae1b30	fa18eb5b-c301-4e26-93a1-021d57c20c2e	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
65ea1e9b-036b-4336-990a-e8ed7d7b465e	ca3df605-8cd3-42cd-b7fa-06251da21bef	1	1	0.434	339dee6f-1d8f-482c-8465-a87d2650af5e
c1a9dc43-85c3-4b21-9959-7e1d96f3529c	ca3df605-8cd3-42cd-b7fa-06251da21bef	1	2	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
bd90f8b9-d283-4276-8435-6081d1c6224f	ca3df605-8cd3-42cd-b7fa-06251da21bef	1	3	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
ddae2374-62b8-469e-a70c-9ec32e5766c8	ca3df605-8cd3-42cd-b7fa-06251da21bef	1	4	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
5e326eb0-a018-4aa6-bcbf-eb61b269317e	ca3df605-8cd3-42cd-b7fa-06251da21bef	1	5	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
153cbba2-f542-4a27-af88-3f86962aa5dc	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	1	0.434	339dee6f-1d8f-482c-8465-a87d2650af5e
988671bf-18cd-4622-8a65-67a35e2bd978	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	2	0.651	339dee6f-1d8f-482c-8465-a87d2650af5e
3fa0b213-0133-45b5-b4c6-50d9e955ee1b	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	3	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
f64f4cea-e807-4374-a8e9-8277296bb4ea	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	4	0.651	339dee6f-1d8f-482c-8465-a87d2650af5e
366efcf4-246e-454e-8f58-1e25ce6d2850	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	5	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
1a16d5e1-74eb-4196-84b2-c7f851f49bf6	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	1	0.189	339dee6f-1d8f-482c-8465-a87d2650af5e
f8d277a5-fdbd-4eaf-8f28-7c8363deb5d9	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	2	0.227	339dee6f-1d8f-482c-8465-a87d2650af5e
21392fcc-1982-4394-acc6-f4d0e7165013	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e5076186-d302-4734-825b-5190fcd2f4da	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cf0ea313-663e-4514-8f5d-56dc9e8c476c	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fd2068c3-91fc-4120-b8d8-494d83e99490	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ca6d2e0b-45ee-4b04-af9e-f7b4dbac5879	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	2	0.434	339dee6f-1d8f-482c-8465-a87d2650af5e
c44416c3-6964-4cb5-8c25-37094f0e61b3	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	3	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
a427c3cc-6e9a-45ab-bae9-075496265843	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	4	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
41531670-812a-4024-9b53-db9beb951fdf	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	5	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
791fbd93-9aa9-4e50-88b4-90f4d5185945	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e8dbc230-7894-4678-9e6f-ed0d5d18baaf	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	2	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
347d3109-168b-4230-9c8c-4474a47ae0ba	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	3	1.736	339dee6f-1d8f-482c-8465-a87d2650af5e
8d3d67a6-f115-400e-90cc-115ef2c6071b	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	4	1.736	339dee6f-1d8f-482c-8465-a87d2650af5e
7cdc4f1f-ba8b-4d40-bfa7-6972fc4f34f6	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	5	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
6e1fe002-7d2a-41d3-be79-bd8cac6f2cf9	ca3df605-8cd3-42cd-b7fa-06251da21bef	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e13f43d6-e90b-4807-8ec1-e609c8d92f93	ca3df605-8cd3-42cd-b7fa-06251da21bef	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b7d742d7-6cd4-46c3-a476-1fd9ab5cd893	ca3df605-8cd3-42cd-b7fa-06251da21bef	6	3	1.230	339dee6f-1d8f-482c-8465-a87d2650af5e
aa721807-1a54-4c52-8a84-9a99daf776a9	ca3df605-8cd3-42cd-b7fa-06251da21bef	6	4	2.270	339dee6f-1d8f-482c-8465-a87d2650af5e
94f06a11-3ef5-4bc6-86e6-49fc1f2bc538	ca3df605-8cd3-42cd-b7fa-06251da21bef	6	5	0.189	339dee6f-1d8f-482c-8465-a87d2650af5e
54ecb838-ce30-4e15-af4a-6b50765290d0	ca3df605-8cd3-42cd-b7fa-06251da21bef	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4d9a19e9-4aac-41b2-8259-963bddf0b7f5	ca3df605-8cd3-42cd-b7fa-06251da21bef	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8c57bfc6-00c8-4c79-bcaf-8a8933c14ff0	ca3df605-8cd3-42cd-b7fa-06251da21bef	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
eb8cae58-3ce4-4089-a14c-70c0e49185bc	ca3df605-8cd3-42cd-b7fa-06251da21bef	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cc4b7c8-61a8-4a67-88a6-5ed5cf554c5f	ca3df605-8cd3-42cd-b7fa-06251da21bef	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d15951c9-dbc4-4b0d-8669-bf5f8cf5502c	ca3df605-8cd3-42cd-b7fa-06251da21bef	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f9e1b6d8-6d94-4262-9e31-6f87015c29eb	ca3df605-8cd3-42cd-b7fa-06251da21bef	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dd8e87be-cad5-4153-8eba-07bcc0689e49	ca3df605-8cd3-42cd-b7fa-06251da21bef	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
19ec2dc0-2122-4084-87c1-d9deed3529b6	ca3df605-8cd3-42cd-b7fa-06251da21bef	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e07d325f-bc70-4a4f-8867-5dbb510350b8	ca3df605-8cd3-42cd-b7fa-06251da21bef	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9c0af08d-cf46-4fe0-a732-f4d3c2e599a7	ca3df605-8cd3-42cd-b7fa-06251da21bef	9	1	0.567	339dee6f-1d8f-482c-8465-a87d2650af5e
f07830b0-b292-4683-aa4b-90a286851af0	ca3df605-8cd3-42cd-b7fa-06251da21bef	9	2	0.946	339dee6f-1d8f-482c-8465-a87d2650af5e
c5757b00-c961-4998-9ee1-64122d0101aa	ca3df605-8cd3-42cd-b7fa-06251da21bef	9	3	1.892	339dee6f-1d8f-482c-8465-a87d2650af5e
0d33b091-ee2e-4bd7-b115-d9ba50ff9079	ca3df605-8cd3-42cd-b7fa-06251da21bef	9	4	0.757	339dee6f-1d8f-482c-8465-a87d2650af5e
c3fefb89-8bd7-4b8a-8f5d-efa6b422b937	ca3df605-8cd3-42cd-b7fa-06251da21bef	9	5	0.378	339dee6f-1d8f-482c-8465-a87d2650af5e
bc8408f2-960d-4ddc-9249-6c43c8c77aff	ca3df605-8cd3-42cd-b7fa-06251da21bef	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
00caac83-aeea-4bcf-93a1-433633036420	ca3df605-8cd3-42cd-b7fa-06251da21bef	10	2	0.378	339dee6f-1d8f-482c-8465-a87d2650af5e
3ebd625d-0ef9-4044-b911-258ea80f4c05	ca3df605-8cd3-42cd-b7fa-06251da21bef	10	3	0.757	339dee6f-1d8f-482c-8465-a87d2650af5e
42fd62dd-9c84-4e62-b5e9-a31c7a9dec20	ca3df605-8cd3-42cd-b7fa-06251da21bef	10	4	0.757	339dee6f-1d8f-482c-8465-a87d2650af5e
28f85314-87a8-4262-8538-5e9b4b8e022f	ca3df605-8cd3-42cd-b7fa-06251da21bef	10	5	0.189	339dee6f-1d8f-482c-8465-a87d2650af5e
5bffee03-4e71-40ae-8e8b-f316976e3fca	ca3df605-8cd3-42cd-b7fa-06251da21bef	11	1	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
ce9bd6ef-447e-4606-a738-7d3818f78cab	ca3df605-8cd3-42cd-b7fa-06251da21bef	11	2	0.347	339dee6f-1d8f-482c-8465-a87d2650af5e
b51a3206-2d7c-459f-bbde-c2e28a6359e8	ca3df605-8cd3-42cd-b7fa-06251da21bef	11	3	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
c00d1148-e055-4515-8f19-5e116685e2dd	ca3df605-8cd3-42cd-b7fa-06251da21bef	11	4	0.868	339dee6f-1d8f-482c-8465-a87d2650af5e
aa2bc7d1-a8b7-493f-99e5-1af12d9ed833	ca3df605-8cd3-42cd-b7fa-06251da21bef	11	5	0.217	339dee6f-1d8f-482c-8465-a87d2650af5e
f4c942e7-1a74-4241-9761-911dc86d2147	ca3df605-8cd3-42cd-b7fa-06251da21bef	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8dca4d33-a6e5-4ecc-9db6-bd60ef7c4efb	ca3df605-8cd3-42cd-b7fa-06251da21bef	12	2	0.378	339dee6f-1d8f-482c-8465-a87d2650af5e
c1d25f2f-c55f-4de1-9d5f-a3fca921b3c7	ca3df605-8cd3-42cd-b7fa-06251da21bef	12	3	1.513	339dee6f-1d8f-482c-8465-a87d2650af5e
b7f22ed6-cd58-4828-b66a-31ce75a2a52a	ca3df605-8cd3-42cd-b7fa-06251da21bef	12	4	1.513	339dee6f-1d8f-482c-8465-a87d2650af5e
9568c29b-19ab-480f-9319-74abcb5e1175	ca3df605-8cd3-42cd-b7fa-06251da21bef	12	5	0.236	339dee6f-1d8f-482c-8465-a87d2650af5e
d72a1637-1ee0-4ab3-acdc-433bc38d1acd	ca3df605-8cd3-42cd-b7fa-06251da21bef	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f5edc33a-30c5-4a3a-b46e-99e0dcf652a0	ca3df605-8cd3-42cd-b7fa-06251da21bef	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
87398d87-4a52-4265-b312-eeaff5fcd5a6	ca3df605-8cd3-42cd-b7fa-06251da21bef	13	3	1.135	339dee6f-1d8f-482c-8465-a87d2650af5e
431deceb-2e68-478f-affa-80f9ddca5609	ca3df605-8cd3-42cd-b7fa-06251da21bef	13	4	1.362	339dee6f-1d8f-482c-8465-a87d2650af5e
cf48c07c-ddb4-437d-abe5-a2dafddbe8bb	ca3df605-8cd3-42cd-b7fa-06251da21bef	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bb13cc04-4b1e-4e50-9b97-d47678ff3225	ca3df605-8cd3-42cd-b7fa-06251da21bef	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f50363fa-7958-4159-b005-f0df48eae6b6	ca3df605-8cd3-42cd-b7fa-06251da21bef	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
55618e1b-d496-4a44-b204-74a6053075cc	ca3df605-8cd3-42cd-b7fa-06251da21bef	14	3	0.142	339dee6f-1d8f-482c-8465-a87d2650af5e
eff3173b-252e-4bd1-9269-b09f15ae6f2b	ca3df605-8cd3-42cd-b7fa-06251da21bef	14	4	0.142	339dee6f-1d8f-482c-8465-a87d2650af5e
54f0b91b-d9f2-4cfc-bd6a-7f3f67c665cd	ca3df605-8cd3-42cd-b7fa-06251da21bef	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f5de32d8-479a-4b5e-b0da-7dd75003ed03	ca3df605-8cd3-42cd-b7fa-06251da21bef	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bafd8f8f-0259-453c-832b-ab03712397eb	ca3df605-8cd3-42cd-b7fa-06251da21bef	15	2	0.378	339dee6f-1d8f-482c-8465-a87d2650af5e
f5e0d4c7-b0b8-4310-841a-b31061b4e12f	ca3df605-8cd3-42cd-b7fa-06251da21bef	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bbb7aaf4-51ac-4e37-b26d-2a7bb1ed275b	ca3df605-8cd3-42cd-b7fa-06251da21bef	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
90fbd653-96e8-4667-a90a-6e750761232f	ca3df605-8cd3-42cd-b7fa-06251da21bef	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
66dac55d-e41b-44ac-9572-2fe8996c0db2	ca3df605-8cd3-42cd-b7fa-06251da21bef	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d8ca66b9-1b5d-4fe6-b1a2-51b816eabaa6	ca3df605-8cd3-42cd-b7fa-06251da21bef	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fc32e536-9e79-4548-9cc1-bbcab143edfd	ca3df605-8cd3-42cd-b7fa-06251da21bef	16	3	0.227	339dee6f-1d8f-482c-8465-a87d2650af5e
89692970-4c1d-4775-8687-7b8f4804569c	ca3df605-8cd3-42cd-b7fa-06251da21bef	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bd90dc86-c034-4a4c-8aec-a499c2d09748	ca3df605-8cd3-42cd-b7fa-06251da21bef	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0536848f-fe2c-465e-a6ed-bd701b400879	ca3df605-8cd3-42cd-b7fa-06251da21bef	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
04900c75-5c71-416c-b8a1-59d4651aa871	ca3df605-8cd3-42cd-b7fa-06251da21bef	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a624b06e-5494-4d58-a672-c4f2ab51d013	ca3df605-8cd3-42cd-b7fa-06251da21bef	17	3	0.284	339dee6f-1d8f-482c-8465-a87d2650af5e
45b35c11-cf80-4a08-af94-178c27cd00f9	ca3df605-8cd3-42cd-b7fa-06251da21bef	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
50547c26-9f9c-49e2-bd7f-147926f55354	ca3df605-8cd3-42cd-b7fa-06251da21bef	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cfd2f0f7-0cc3-402e-9c4f-8108d21a85e7	ca3df605-8cd3-42cd-b7fa-06251da21bef	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
45c51c9e-e87e-4d79-979d-9ee61a7b3f8f	ca3df605-8cd3-42cd-b7fa-06251da21bef	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f20f472f-6293-4ce9-b5f6-8b65a5e1925d	ca3df605-8cd3-42cd-b7fa-06251da21bef	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
632d6c38-0f13-4c60-9301-3adb8dc65dd3	ca3df605-8cd3-42cd-b7fa-06251da21bef	18	4	0.284	339dee6f-1d8f-482c-8465-a87d2650af5e
665e7bac-83ab-4a0a-8e62-567fc665b5e3	ca3df605-8cd3-42cd-b7fa-06251da21bef	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
47019e92-7108-40d5-a5d1-b9d3d7d35097	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	1	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
caac9704-2c75-4ed5-84f8-950ea2a7c6c3	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	2	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
af0db9cd-1252-4bff-b02b-6930479a6685	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	3	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
9f3c3d98-b26a-4a41-a8d1-074ad63f739f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	4	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
651ed283-5e0b-4c54-99fb-0e784b27ab16	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	5	0.171	339dee6f-1d8f-482c-8465-a87d2650af5e
2da6e3d5-79f6-40d8-86b6-799a8701438f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	1	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
2c9cde20-19a3-49f9-bec6-9863db190bc7	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	2	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
d2ae1f3f-b1fa-474c-bb41-3591f880cef7	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	3	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
1108be79-ccd4-415f-b5c1-bf3755b7ecde	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	4	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
4c68bf69-e3cf-48ff-a7a1-94fe7ef2dc5f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	5	0.171	339dee6f-1d8f-482c-8465-a87d2650af5e
e037ce78-c044-4071-9076-bf745604854f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	1	0.122	339dee6f-1d8f-482c-8465-a87d2650af5e
552fdf8c-ff97-4a78-9a60-b120879ce9f2	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	2	0.146	339dee6f-1d8f-482c-8465-a87d2650af5e
588aed6e-1ba7-4aa8-b7ba-e17cc5dd53d8	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
18009d14-6fae-4d51-bae9-95d22e071ff3	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0fecfb6f-57c9-40f0-a1b8-c82dea8d5751	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ed8e5e95-ebf3-4c1c-9bb8-cb713589c015	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
958be677-e7ef-42c1-8647-e9704cdf2cf1	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	2	0.343	339dee6f-1d8f-482c-8465-a87d2650af5e
a9b92ab3-b30c-42b9-a1c5-5db962bb001c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	3	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
25c7d250-342d-4766-ad9b-0d98b98374e7	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	4	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
0ee2bd77-cd72-4ef7-903f-5b80103514f5	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	5	0.171	339dee6f-1d8f-482c-8465-a87d2650af5e
de41b165-9565-4e1e-a0b2-c63978caef16	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6451ddec-b132-4964-a394-9aef795d4288	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	2	1.028	339dee6f-1d8f-482c-8465-a87d2650af5e
d11b607e-573d-40d6-b049-ebed658b3fff	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	3	2.055	339dee6f-1d8f-482c-8465-a87d2650af5e
944f561c-1a59-45d9-918e-cb4080748591	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	4	2.055	339dee6f-1d8f-482c-8465-a87d2650af5e
c29f4c17-cdbf-473a-8b20-0ce8395e1d47	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	5	0.257	339dee6f-1d8f-482c-8465-a87d2650af5e
bf6232e2-4fc9-4cae-afcb-dd27ded1518c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e8cc978a-0f27-4ffd-b6fe-bb28c6c0c213	94a133f2-836f-4d8e-a401-9cc4a5e341d5	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ed814c4c-2a50-4197-818f-28e9f7a7e8ba	94a133f2-836f-4d8e-a401-9cc4a5e341d5	6	3	0.790	339dee6f-1d8f-482c-8465-a87d2650af5e
61e357b6-4b22-4989-b91e-0a0910a3eeb9	94a133f2-836f-4d8e-a401-9cc4a5e341d5	6	4	1.823	339dee6f-1d8f-482c-8465-a87d2650af5e
59a93a13-f7df-4eb7-839a-ce7ecfa8a56c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	6	5	0.122	339dee6f-1d8f-482c-8465-a87d2650af5e
99496391-77ec-407d-9ef8-de66ba59ac36	94a133f2-836f-4d8e-a401-9cc4a5e341d5	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1a9bbe6f-4303-4f0c-9ef6-ed5859e7d40a	94a133f2-836f-4d8e-a401-9cc4a5e341d5	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7b5d24af-1327-4dd5-91f4-3527414d756f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0dc94ddf-e52b-414f-80b1-3a62d0a03a19	94a133f2-836f-4d8e-a401-9cc4a5e341d5	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
97f932f5-8bf2-41d5-b2a3-0aa6c5f0e027	94a133f2-836f-4d8e-a401-9cc4a5e341d5	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
90546c9a-0b58-4b99-904c-dc090a579a6f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	8	1	0.425	339dee6f-1d8f-482c-8465-a87d2650af5e
1dc4d203-6b00-4891-a5ff-71ad84c1ede6	94a133f2-836f-4d8e-a401-9cc4a5e341d5	8	2	1.216	339dee6f-1d8f-482c-8465-a87d2650af5e
8cf86f24-4465-43c0-8c1d-eea54e64b164	94a133f2-836f-4d8e-a401-9cc4a5e341d5	8	3	1.216	339dee6f-1d8f-482c-8465-a87d2650af5e
1dda16c2-a847-40cd-a609-bf9c1a36880b	94a133f2-836f-4d8e-a401-9cc4a5e341d5	8	4	0.608	339dee6f-1d8f-482c-8465-a87d2650af5e
8db9de6e-f6e7-4fbd-a0bc-c3874e35aff4	94a133f2-836f-4d8e-a401-9cc4a5e341d5	8	5	0.243	339dee6f-1d8f-482c-8465-a87d2650af5e
8ff41633-3aac-4bff-9fdb-b7b9a5ef6737	94a133f2-836f-4d8e-a401-9cc4a5e341d5	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
500940bc-c99b-4f33-bc34-03155b8301bc	94a133f2-836f-4d8e-a401-9cc4a5e341d5	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
328cc48b-5536-4eaf-8522-1422dfc284c4	94a133f2-836f-4d8e-a401-9cc4a5e341d5	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4bfe8ad9-0697-4c9c-b1ad-c54fd4c9f3df	94a133f2-836f-4d8e-a401-9cc4a5e341d5	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dcb0008c-8ee3-40a4-8b90-f94bc86b1ff5	94a133f2-836f-4d8e-a401-9cc4a5e341d5	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6773806-e053-4f0f-8d61-0d8f63daef6d	94a133f2-836f-4d8e-a401-9cc4a5e341d5	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a986bc16-98ff-4880-badc-623b49ee23ce	94a133f2-836f-4d8e-a401-9cc4a5e341d5	10	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6533e9e3-a493-463f-b512-210434a16505	94a133f2-836f-4d8e-a401-9cc4a5e341d5	10	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
602405b7-e646-4802-b8aa-f2d8dbc4d0bd	94a133f2-836f-4d8e-a401-9cc4a5e341d5	10	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
463996be-2673-4b08-9b2d-eede0606d1d9	94a133f2-836f-4d8e-a401-9cc4a5e341d5	10	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
97694105-a90a-49dd-a4e3-2ae78a50d282	94a133f2-836f-4d8e-a401-9cc4a5e341d5	11	1	0.171	339dee6f-1d8f-482c-8465-a87d2650af5e
d7a1bf9a-be7e-485d-92ff-476c55eda3ba	94a133f2-836f-4d8e-a401-9cc4a5e341d5	11	2	0.274	339dee6f-1d8f-482c-8465-a87d2650af5e
6d862cc5-89f1-457c-9414-ab61a5d9d85b	94a133f2-836f-4d8e-a401-9cc4a5e341d5	11	3	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
30f13512-1e64-40a5-9055-7ae7294cba2d	94a133f2-836f-4d8e-a401-9cc4a5e341d5	11	4	0.685	339dee6f-1d8f-482c-8465-a87d2650af5e
ddf12c32-2490-426c-8f2c-41e95203b6ff	94a133f2-836f-4d8e-a401-9cc4a5e341d5	11	5	0.171	339dee6f-1d8f-482c-8465-a87d2650af5e
451557b9-c111-4f8b-94ef-c0b7a1db89d4	94a133f2-836f-4d8e-a401-9cc4a5e341d5	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d8cbbd11-9544-46a9-b043-c7a183be824a	94a133f2-836f-4d8e-a401-9cc4a5e341d5	12	2	0.304	339dee6f-1d8f-482c-8465-a87d2650af5e
2adceec1-1db2-4e95-8aab-dd8094c78d61	94a133f2-836f-4d8e-a401-9cc4a5e341d5	12	3	2.431	339dee6f-1d8f-482c-8465-a87d2650af5e
b8d861f3-305c-4f17-867c-617fe6d38b8c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	12	4	3.039	339dee6f-1d8f-482c-8465-a87d2650af5e
e9cee3b1-967d-4742-9b8b-13c9f2807b56	94a133f2-836f-4d8e-a401-9cc4a5e341d5	12	5	0.152	339dee6f-1d8f-482c-8465-a87d2650af5e
22662fc4-0f12-49f8-9e54-4ef9196ca0e4	94a133f2-836f-4d8e-a401-9cc4a5e341d5	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
81d7495e-20ca-4bd7-9b12-4010cb9603e8	94a133f2-836f-4d8e-a401-9cc4a5e341d5	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
153afcd1-f0dd-42ad-bd2b-42764343944f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	13	3	0.729	339dee6f-1d8f-482c-8465-a87d2650af5e
a677c2fd-3961-4461-a38d-3a82ef393236	94a133f2-836f-4d8e-a401-9cc4a5e341d5	13	4	0.875	339dee6f-1d8f-482c-8465-a87d2650af5e
38a2f011-e27b-4227-96b1-dc4c92ebf0d2	94a133f2-836f-4d8e-a401-9cc4a5e341d5	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
41addba1-b575-45ba-9af6-1d1e6e5e284a	94a133f2-836f-4d8e-a401-9cc4a5e341d5	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6c2ecda-ae4d-4d9d-a427-ef5a9d068a7d	94a133f2-836f-4d8e-a401-9cc4a5e341d5	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ad164e83-e781-4165-a157-d1e192b39a2d	94a133f2-836f-4d8e-a401-9cc4a5e341d5	14	3	0.091	339dee6f-1d8f-482c-8465-a87d2650af5e
1ef0c898-bc35-4ad8-8e30-cd69766fec84	94a133f2-836f-4d8e-a401-9cc4a5e341d5	14	4	0.091	339dee6f-1d8f-482c-8465-a87d2650af5e
72b2bd91-4e87-4eab-a889-4bf0e1e00d17	94a133f2-836f-4d8e-a401-9cc4a5e341d5	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ef042d0c-5c15-4f8c-8328-619354670466	94a133f2-836f-4d8e-a401-9cc4a5e341d5	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4edd590c-2f40-4770-bd82-57f000a0c624	94a133f2-836f-4d8e-a401-9cc4a5e341d5	15	2	0.182	339dee6f-1d8f-482c-8465-a87d2650af5e
d5190e0e-669e-4e47-b1f1-9eb3e81e0f5c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9441037a-55d6-4d79-9907-716f55007876	94a133f2-836f-4d8e-a401-9cc4a5e341d5	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
435108b3-5f1e-4a73-9e47-80a8cde3bc96	94a133f2-836f-4d8e-a401-9cc4a5e341d5	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c60a2cd6-0184-4435-a95b-c499f3e54f35	94a133f2-836f-4d8e-a401-9cc4a5e341d5	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b945249e-f6e8-45f5-af6c-9f9b9018d4f2	94a133f2-836f-4d8e-a401-9cc4a5e341d5	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b659322-965c-4c54-a071-18d9abc51a9f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	16	3	0.182	339dee6f-1d8f-482c-8465-a87d2650af5e
3e3524d0-3d89-4ff0-8b30-87a2bd63b7c2	94a133f2-836f-4d8e-a401-9cc4a5e341d5	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
073c205c-7e4b-4953-abe2-2ecbe1123cfc	94a133f2-836f-4d8e-a401-9cc4a5e341d5	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
564d28ab-1733-46a3-b9ab-dc28f0ac35b7	94a133f2-836f-4d8e-a401-9cc4a5e341d5	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
069181f6-2866-4872-b2b0-b261b82c316f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
14bcd048-9240-4e7c-ad65-e00eddf3b81f	94a133f2-836f-4d8e-a401-9cc4a5e341d5	17	3	0.243	339dee6f-1d8f-482c-8465-a87d2650af5e
85e6f17d-29a7-4426-9fce-7ed12f3c6f20	94a133f2-836f-4d8e-a401-9cc4a5e341d5	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
27e03965-fc03-46ca-998f-ef489c2928dd	94a133f2-836f-4d8e-a401-9cc4a5e341d5	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dacfd7e5-4285-4c50-b8f9-39856c9fb19c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d70af917-6ffd-4b4e-b95f-101711f0a9c0	94a133f2-836f-4d8e-a401-9cc4a5e341d5	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8385d58a-9b11-4563-ad09-529e8635b34a	94a133f2-836f-4d8e-a401-9cc4a5e341d5	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ee07e55b-a4ba-49a2-8fb9-65dbe606e5f1	94a133f2-836f-4d8e-a401-9cc4a5e341d5	18	4	0.182	339dee6f-1d8f-482c-8465-a87d2650af5e
3a3d614f-afe4-49e4-9576-1949c8d5c37c	94a133f2-836f-4d8e-a401-9cc4a5e341d5	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f9a321bd-2a0f-452e-b909-195c281ac850	090d1fef-0165-4070-9abd-589bd74de796	1	1	0.678	339dee6f-1d8f-482c-8465-a87d2650af5e
5f202268-a4e2-4e69-9b66-3a91975b2d19	090d1fef-0165-4070-9abd-589bd74de796	1	2	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
469a0c66-eec2-476f-b484-4d46d7cb6d55	090d1fef-0165-4070-9abd-589bd74de796	1	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
24eb5a12-7878-4098-a1a7-7c25cf4f38b9	090d1fef-0165-4070-9abd-589bd74de796	1	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
4d906f3b-6595-4a59-a81f-a89259fd4324	090d1fef-0165-4070-9abd-589bd74de796	1	5	0.452	339dee6f-1d8f-482c-8465-a87d2650af5e
404c32f7-6ba5-4eef-8697-825c58e904bc	090d1fef-0165-4070-9abd-589bd74de796	2	1	0.678	339dee6f-1d8f-482c-8465-a87d2650af5e
75f9a244-88d5-4bbb-af95-c48ad54a863f	090d1fef-0165-4070-9abd-589bd74de796	2	2	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
edbd8d09-e534-491c-ae73-b7cdf8e5eb40	090d1fef-0165-4070-9abd-589bd74de796	2	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
d9ab08d4-9106-4709-9c8e-5a1eb4fd1e47	090d1fef-0165-4070-9abd-589bd74de796	2	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
0e4cb2cb-2ab0-4159-be29-f3e5f5fbd6b4	090d1fef-0165-4070-9abd-589bd74de796	2	5	0.452	339dee6f-1d8f-482c-8465-a87d2650af5e
f5c6e851-ac0f-4aba-b240-668a3b6f7202	090d1fef-0165-4070-9abd-589bd74de796	3	1	0.890	339dee6f-1d8f-482c-8465-a87d2650af5e
b743f2e7-be8c-4662-855a-6cb4ba304ebe	090d1fef-0165-4070-9abd-589bd74de796	3	2	0.445	339dee6f-1d8f-482c-8465-a87d2650af5e
6bbc8bed-bc49-40c3-86a0-86f3c11e7d47	090d1fef-0165-4070-9abd-589bd74de796	3	3	0.445	339dee6f-1d8f-482c-8465-a87d2650af5e
e57bbcc9-f648-48a4-9cf4-9fd630364237	090d1fef-0165-4070-9abd-589bd74de796	3	4	0.445	339dee6f-1d8f-482c-8465-a87d2650af5e
615e575d-a898-4bfa-88bd-fb8ffbef82d9	090d1fef-0165-4070-9abd-589bd74de796	3	5	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
36389c9f-21ba-4e51-9c8c-3f4f74bad2ac	090d1fef-0165-4070-9abd-589bd74de796	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32784123-d56e-4e90-ac68-85019de20607	090d1fef-0165-4070-9abd-589bd74de796	4	2	0.452	339dee6f-1d8f-482c-8465-a87d2650af5e
4f631004-4d69-4b56-ab8a-e4def3fd8df7	090d1fef-0165-4070-9abd-589bd74de796	4	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
c5970935-b7d0-402d-8d65-d72d055136fa	090d1fef-0165-4070-9abd-589bd74de796	4	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
97eb6537-20b9-4747-a297-e6f0ddb5bf91	090d1fef-0165-4070-9abd-589bd74de796	4	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
e403bb22-bc70-4efa-888a-9a5cb1d489cc	090d1fef-0165-4070-9abd-589bd74de796	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ced585ac-4ffb-402f-80d7-23bee1dda817	090d1fef-0165-4070-9abd-589bd74de796	5	2	1.356	339dee6f-1d8f-482c-8465-a87d2650af5e
fe86915b-41b9-4a66-9850-385dfa374389	090d1fef-0165-4070-9abd-589bd74de796	5	3	2.713	339dee6f-1d8f-482c-8465-a87d2650af5e
76cb6c86-bd5e-4c48-95ec-40135d4ac0cf	090d1fef-0165-4070-9abd-589bd74de796	5	4	2.713	339dee6f-1d8f-482c-8465-a87d2650af5e
6a24f5c0-8904-4ea0-bc58-6cc95f256cee	090d1fef-0165-4070-9abd-589bd74de796	5	5	0.678	339dee6f-1d8f-482c-8465-a87d2650af5e
2b954c81-995c-4b94-8186-ff2b16ce65a6	090d1fef-0165-4070-9abd-589bd74de796	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
94a31d9a-02b3-4f21-981a-71f019bb3e54	090d1fef-0165-4070-9abd-589bd74de796	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
96825a95-4d41-4d64-8594-d88f23a97b30	090d1fef-0165-4070-9abd-589bd74de796	6	3	5.788	339dee6f-1d8f-482c-8465-a87d2650af5e
8573641a-aa83-4797-872e-581d2fc42ecc	090d1fef-0165-4070-9abd-589bd74de796	6	4	6.678	339dee6f-1d8f-482c-8465-a87d2650af5e
666b3c31-7db8-463b-9ed2-0bb46376fb3a	090d1fef-0165-4070-9abd-589bd74de796	6	5	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
3b2115d6-165b-4ec0-bc64-1eec7c386258	090d1fef-0165-4070-9abd-589bd74de796	7	1	0.779	339dee6f-1d8f-482c-8465-a87d2650af5e
79edb1cd-665a-4d6d-a001-fff3bed9b25a	090d1fef-0165-4070-9abd-589bd74de796	7	2	4.007	339dee6f-1d8f-482c-8465-a87d2650af5e
f758b8c8-62b0-418f-a1a2-4ee30bb48b53	090d1fef-0165-4070-9abd-589bd74de796	7	3	2.226	339dee6f-1d8f-482c-8465-a87d2650af5e
c2019d23-17a3-4a5f-a111-b79fcb489419	090d1fef-0165-4070-9abd-589bd74de796	7	4	1.113	339dee6f-1d8f-482c-8465-a87d2650af5e
bd21eb6b-8f8b-4387-acc2-6dfea96249b6	090d1fef-0165-4070-9abd-589bd74de796	7	5	0.445	339dee6f-1d8f-482c-8465-a87d2650af5e
d14cec83-76e0-49c9-9ab7-e3787267013d	090d1fef-0165-4070-9abd-589bd74de796	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5d758118-3d95-4496-b76a-7545dc63e22b	090d1fef-0165-4070-9abd-589bd74de796	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6888ba5f-855b-42ad-9e06-6f3f548d011c	090d1fef-0165-4070-9abd-589bd74de796	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3e14fc13-6e2b-432b-9f0b-4c98c8a14c20	090d1fef-0165-4070-9abd-589bd74de796	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3c1ee2aa-5d73-4522-8182-7d486800a5aa	090d1fef-0165-4070-9abd-589bd74de796	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5e234716-ecb7-499d-913f-4238021c46db	090d1fef-0165-4070-9abd-589bd74de796	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1c976071-a9b7-4537-82ba-08c36620581f	090d1fef-0165-4070-9abd-589bd74de796	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
51621d35-98ad-45fb-99ad-186f5c2f1e62	090d1fef-0165-4070-9abd-589bd74de796	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2458aecc-5f5f-4356-a8c5-3f1c2de832c3	090d1fef-0165-4070-9abd-589bd74de796	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1328eb12-b467-40f2-b7dd-c59a8ffd03d8	090d1fef-0165-4070-9abd-589bd74de796	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
56f41a62-2d42-4f88-89d9-5e0c45cf4c05	090d1fef-0165-4070-9abd-589bd74de796	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1594ac36-71f4-412f-b519-963ac24e2f0b	090d1fef-0165-4070-9abd-589bd74de796	10	2	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
2e14424d-5c12-4efc-8ff0-58544d8a9d2b	090d1fef-0165-4070-9abd-589bd74de796	10	3	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
9318c790-d01e-4695-8182-d831b03b24a1	090d1fef-0165-4070-9abd-589bd74de796	10	4	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
7d1626c6-3a31-4ad1-84b6-263b3573d17d	090d1fef-0165-4070-9abd-589bd74de796	10	5	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
a8ea3edd-bae2-4b1e-bc71-1f949bdce991	090d1fef-0165-4070-9abd-589bd74de796	11	1	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
a462114e-547a-464f-ac72-89bcd4e267ce	090d1fef-0165-4070-9abd-589bd74de796	11	2	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
04c5c1ad-17b5-40fb-bfc9-0b92f103e8c4	090d1fef-0165-4070-9abd-589bd74de796	11	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
b1b6eff3-4ee5-41aa-bc2c-dc86872cd263	090d1fef-0165-4070-9abd-589bd74de796	11	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
1c80999e-cbaf-4260-ba18-6e3025caace7	090d1fef-0165-4070-9abd-589bd74de796	11	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
7289a288-40f6-4406-bf77-86b14d98bae8	090d1fef-0165-4070-9abd-589bd74de796	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4e6d4e80-4c7d-437d-81ee-21ee60d8d503	090d1fef-0165-4070-9abd-589bd74de796	12	2	1.781	339dee6f-1d8f-482c-8465-a87d2650af5e
54a8f5f0-a5bd-4dc9-8544-b8a9edbf464b	090d1fef-0165-4070-9abd-589bd74de796	12	3	3.562	339dee6f-1d8f-482c-8465-a87d2650af5e
f6753ae5-e26c-4089-bcee-b7713e46273b	090d1fef-0165-4070-9abd-589bd74de796	12	4	4.452	339dee6f-1d8f-482c-8465-a87d2650af5e
0de9f507-65a2-47f3-a464-2ecf0c6ce035	090d1fef-0165-4070-9abd-589bd74de796	12	5	0.223	339dee6f-1d8f-482c-8465-a87d2650af5e
fc408b8a-0fc7-4ff9-9842-e28ad2cf34f0	090d1fef-0165-4070-9abd-589bd74de796	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e80ca8ed-7c96-4806-9bfa-b0f2620b6e0c	090d1fef-0165-4070-9abd-589bd74de796	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dc2701e0-a731-4a98-aefa-540d76588e8a	090d1fef-0165-4070-9abd-589bd74de796	13	3	2.671	339dee6f-1d8f-482c-8465-a87d2650af5e
d8b63b8f-5819-4c34-8f11-ac1785fad29e	090d1fef-0165-4070-9abd-589bd74de796	13	4	4.452	339dee6f-1d8f-482c-8465-a87d2650af5e
9c434976-8cc2-49aa-bf92-176f8df8c9f5	090d1fef-0165-4070-9abd-589bd74de796	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
73e187fb-bca4-48a6-8d78-840e2b2a9a7b	090d1fef-0165-4070-9abd-589bd74de796	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0c98ec4d-e020-4d4e-9755-c222827a54d6	090d1fef-0165-4070-9abd-589bd74de796	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c7c7ac58-78aa-4c00-94fb-0882a99ef826	090d1fef-0165-4070-9abd-589bd74de796	14	3	0.668	339dee6f-1d8f-482c-8465-a87d2650af5e
be4b8510-77ef-4322-a6ef-962b602eec49	090d1fef-0165-4070-9abd-589bd74de796	14	4	0.668	339dee6f-1d8f-482c-8465-a87d2650af5e
65f79968-48ad-45b6-ad72-229dda9e7758	090d1fef-0165-4070-9abd-589bd74de796	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63182a4c-7f78-42b8-81f9-bfdd8bdf0d40	090d1fef-0165-4070-9abd-589bd74de796	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6ee73ee9-2d8d-4232-98b3-7cba25c6682e	090d1fef-0165-4070-9abd-589bd74de796	15	2	0.501	339dee6f-1d8f-482c-8465-a87d2650af5e
0da2695f-3870-429d-a1dc-d07f2e61fd94	090d1fef-0165-4070-9abd-589bd74de796	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
534d29e5-a0a7-49a3-81c4-1d7c889598bb	090d1fef-0165-4070-9abd-589bd74de796	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8a26fd55-81d8-4196-86e3-b6e59f815246	090d1fef-0165-4070-9abd-589bd74de796	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ea5234eb-a95c-4208-8b63-7aee263f3009	090d1fef-0165-4070-9abd-589bd74de796	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
417645c7-3455-40e6-b1e1-29c53496c5ac	090d1fef-0165-4070-9abd-589bd74de796	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
053a105c-3627-4e23-b346-aa27f765ed17	090d1fef-0165-4070-9abd-589bd74de796	16	3	1.002	339dee6f-1d8f-482c-8465-a87d2650af5e
58efd747-c308-414d-8257-77295b6e03d7	090d1fef-0165-4070-9abd-589bd74de796	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
64325de4-74e9-4a3e-8668-d5919e8ea7b0	090d1fef-0165-4070-9abd-589bd74de796	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e7aa361a-23dc-4bc5-aa11-8a116196dbf7	090d1fef-0165-4070-9abd-589bd74de796	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
38c40ffb-ec88-41a6-9257-b594a69c6562	090d1fef-0165-4070-9abd-589bd74de796	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fe2f952d-6f87-47d8-9de9-5061c2437b49	090d1fef-0165-4070-9abd-589bd74de796	17	3	3.339	339dee6f-1d8f-482c-8465-a87d2650af5e
90991278-2b33-44fb-93d6-255219f2eb71	090d1fef-0165-4070-9abd-589bd74de796	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1028e2c5-1014-4e84-b7ee-bf624e1f45d7	090d1fef-0165-4070-9abd-589bd74de796	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2a0b3c0d-13b2-448c-96f3-614610c39d8e	090d1fef-0165-4070-9abd-589bd74de796	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
facef4af-4189-4be9-99f5-03b3f11cd392	090d1fef-0165-4070-9abd-589bd74de796	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
212756d4-85e7-46c0-95ef-ad974a90cdb4	090d1fef-0165-4070-9abd-589bd74de796	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5bb37476-1d55-4ce6-a815-5aba016e6d7b	090d1fef-0165-4070-9abd-589bd74de796	18	4	0.445	339dee6f-1d8f-482c-8465-a87d2650af5e
56441bb3-dcaf-46c9-8a58-c3ffd16e2ff5	090d1fef-0165-4070-9abd-589bd74de796	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d3e83c72-16be-4706-9d5c-73f6e095e9a0	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	1	1	0.441	339dee6f-1d8f-482c-8465-a87d2650af5e
970115ed-8b0f-4217-b4ef-99f5d1ef8ed4	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	1	2	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
4043da01-2743-46ee-a8ed-67f72fc635d7	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	1	3	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
68f1ff10-2622-4f07-8a4d-32f592082e9a	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	1	4	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
0aa2bcb7-2f6d-4517-8eec-46e5b3ec9e00	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	1	5	0.220	339dee6f-1d8f-482c-8465-a87d2650af5e
4300f4d7-62dd-42b3-8edf-9e20bba48104	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	1	0.441	339dee6f-1d8f-482c-8465-a87d2650af5e
6fc1f7fc-4179-4560-989f-6e0cf670cfd2	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	2	0.661	339dee6f-1d8f-482c-8465-a87d2650af5e
a0d2ec56-bcc1-4c29-bc69-ff024016f0ae	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	3	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
bb204870-2409-4cbb-bd6e-e21c436608f3	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	4	0.661	339dee6f-1d8f-482c-8465-a87d2650af5e
be3e6b1c-0516-4a13-8fdb-7a032182a2ee	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	5	0.220	339dee6f-1d8f-482c-8465-a87d2650af5e
f24dc0e8-c8ed-4a00-a906-ba982d7b7160	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	1	0.196	339dee6f-1d8f-482c-8465-a87d2650af5e
01dd79b8-8d8b-482b-ad0b-a9af0c882d22	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	2	0.235	339dee6f-1d8f-482c-8465-a87d2650af5e
f4b0ed3f-01d2-4d72-8d52-b2b64dc81ff7	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
10a717e1-6e86-4ecd-b79e-e8a3cfe7bdfa	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5dc71432-3b9e-44bd-bbb2-e5c46d479114	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a21776bf-9fd8-4ed5-ae68-cb7a17fee4eb	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e9b38734-c35a-456f-9936-fff56aa43694	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	2	0.441	339dee6f-1d8f-482c-8465-a87d2650af5e
d6b268c0-3315-42b1-88b7-34faa2660e79	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	3	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
06962e02-b4b7-4aef-bcd1-86d94719d3a0	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	4	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
90f15cb3-3825-461d-b4b7-dc6d91a251af	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	5	0.220	339dee6f-1d8f-482c-8465-a87d2650af5e
9b107e27-f4f5-467d-a243-141114b3236b	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
36dccde7-e82c-4485-bf18-19351bf14b02	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	2	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
6459183a-0110-4ab1-8172-b3289d63de2e	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	3	1.762	339dee6f-1d8f-482c-8465-a87d2650af5e
b607ddff-191f-4a5a-8628-49b2aa78e74d	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	4	1.762	339dee6f-1d8f-482c-8465-a87d2650af5e
df7fe9ba-f0ab-4633-b36f-7248ca2a7eee	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	5	0.220	339dee6f-1d8f-482c-8465-a87d2650af5e
f35ea71c-d255-41e9-beb4-3a9091c5a5cb	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f78d207a-a9d5-4ee4-bac8-ef6d685c9a96	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fdf55d9e-119c-4b91-b064-af575de743ba	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	6	3	1.273	339dee6f-1d8f-482c-8465-a87d2650af5e
63623789-7d42-479c-97cc-d7619f4f4805	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	6	4	2.350	339dee6f-1d8f-482c-8465-a87d2650af5e
843a83d1-2013-4410-85a3-01373a136c7a	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	6	5	0.196	339dee6f-1d8f-482c-8465-a87d2650af5e
4443c5e1-f31b-4752-9b81-d94daca22a57	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ad76a991-9248-43b9-890c-fe60137af6e2	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3790e1e0-fe3f-4048-84fc-93c297a7559d	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8d228cee-5ef2-4845-bbe0-fa613cad9181	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
91839448-e614-44bc-927f-f07af8328804	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
470c00e7-26e6-4412-bb4a-330e74492f73	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
53de2462-7d1f-4299-ad02-e5606f10a7f0	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cbc934b-4dc6-4c66-b634-ed0f2fda22f4	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2c7fd137-1185-4c1e-8c67-821d1f6e8115	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
61b6d57d-b31f-4da2-a2a5-2aa68777b2d6	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5435433d-fcb0-4a42-894c-538c654e9f64	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	9	1	0.587	339dee6f-1d8f-482c-8465-a87d2650af5e
d744b48a-b64a-4f3b-a34d-e886dad0ae55	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	9	2	0.979	339dee6f-1d8f-482c-8465-a87d2650af5e
b5407fad-d7d4-4831-b809-a4b301c8dd34	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	9	3	1.958	339dee6f-1d8f-482c-8465-a87d2650af5e
f04edfb2-7f3a-4689-9645-40553a80c906	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	9	4	0.783	339dee6f-1d8f-482c-8465-a87d2650af5e
50b71aa2-773a-45d8-8c09-74409cae417f	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	9	5	0.392	339dee6f-1d8f-482c-8465-a87d2650af5e
2fb5b794-173f-4183-a74d-1bb8237877a0	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
866b71a9-0fec-4ffe-99c7-6a08ac66aefc	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	10	2	0.392	339dee6f-1d8f-482c-8465-a87d2650af5e
411ab6e4-2a56-4e33-9776-f1cfd3d13d89	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	10	3	0.783	339dee6f-1d8f-482c-8465-a87d2650af5e
65f7b5ee-5d47-4074-a389-83f65d814f51	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	10	4	0.783	339dee6f-1d8f-482c-8465-a87d2650af5e
1d7a95ad-c3e8-4626-a2d3-99cd87adffcf	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	10	5	0.196	339dee6f-1d8f-482c-8465-a87d2650af5e
49d97458-ca00-4864-aed9-da3acf4e54c8	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	11	1	0.220	339dee6f-1d8f-482c-8465-a87d2650af5e
07d75a43-96c2-422d-92e0-36f9643214ff	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	11	2	0.352	339dee6f-1d8f-482c-8465-a87d2650af5e
4a7e42ba-2836-4b75-ac7f-6fb8040910a2	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	11	3	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
5c9db2e3-bb98-4b23-a7c9-31ad9d4a41a8	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	11	4	0.881	339dee6f-1d8f-482c-8465-a87d2650af5e
a453e5d6-306c-461c-b773-1bb5a1e630da	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	11	5	0.220	339dee6f-1d8f-482c-8465-a87d2650af5e
079c54ce-9342-4b42-b2df-27fa2549b480	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a3b6562a-3aaa-4a93-8551-19c5e9699576	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	12	2	0.392	339dee6f-1d8f-482c-8465-a87d2650af5e
5c6452d4-356f-4c19-88dd-96f482a6edd1	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	12	3	1.566	339dee6f-1d8f-482c-8465-a87d2650af5e
95d9d23a-7eb6-4bb3-b664-811c060869ef	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	12	4	1.566	339dee6f-1d8f-482c-8465-a87d2650af5e
a39f8985-603e-4fec-92db-015fbae05a5c	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	12	5	0.245	339dee6f-1d8f-482c-8465-a87d2650af5e
b82dda66-3705-4b1f-8087-ebf8a096dc75	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
59ac6388-6ad6-4896-8adb-b4baeff8b1af	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
44e0ceda-9a1d-41c3-8a24-59f1fd53e138	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	13	3	1.175	339dee6f-1d8f-482c-8465-a87d2650af5e
161f7e36-3d22-42dc-aed6-0bd4001c4f9a	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	13	4	1.410	339dee6f-1d8f-482c-8465-a87d2650af5e
e615b0c3-af76-4ef8-8025-1249daaf0025	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
43c9a762-f920-4461-874d-2e00d112e5de	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dc7c5645-b1eb-4590-b90c-03b91719b9f1	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4c9d76a4-9f23-47eb-a80b-5f3e67886e0b	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	14	3	0.147	339dee6f-1d8f-482c-8465-a87d2650af5e
2f2fc0dd-cae6-45ec-ad03-7c6158173699	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	14	4	0.147	339dee6f-1d8f-482c-8465-a87d2650af5e
a178d10a-bb05-4d9d-b843-c1931462d7c2	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
18fda430-3d05-49e8-ae36-25be0cdf1471	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3be0173c-0363-4be9-a185-c1951aa39749	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	15	2	0.392	339dee6f-1d8f-482c-8465-a87d2650af5e
d9ca2a6e-609f-4b4a-8e8c-5d96eed66d23	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4d471988-4f18-4eb6-a1ae-0b82c30b0a21	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ada83ac1-6455-4f52-9aa2-3aa197773b87	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5e54433e-9987-4505-8e1a-836c06500a5e	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a1c5920-0780-49e1-94e4-845b6a7a7363	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6963dbba-5041-4a86-b0c6-25a96e81d13e	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	16	3	0.235	339dee6f-1d8f-482c-8465-a87d2650af5e
7b1e66c6-53cd-43cc-b5b7-7ed93133712b	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b3b0721b-4d98-463f-be0c-5b50521369d4	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
026c3ed0-13b0-4f28-bf3c-d38287a25f13	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
89a8e60e-5f26-4eb5-8670-2247d16ee482	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
45849b88-fcbe-4fca-aee1-321845b65ac8	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	17	3	0.294	339dee6f-1d8f-482c-8465-a87d2650af5e
8d325bc5-b26a-4fba-9da1-04f59e725ab1	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fc38f2c7-e4cf-4fad-88f3-3d7a02469f70	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
39899249-f1da-41d3-b092-7d1e4fb12f18	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54d63be1-c5cb-4822-a894-12ed88ffa223	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
83aaaeaa-6024-4cee-97a7-5af549541419	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
80d97a25-0c21-4caf-b85c-2f30d705e285	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	18	4	0.294	339dee6f-1d8f-482c-8465-a87d2650af5e
f15b2a3d-7e28-4f83-86c2-826e16842a5c	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a0725e81-8ec9-4a57-a660-7e828bc76c55	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	1	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
99f63512-9318-4a91-99b2-b9ee708cfb28	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
6c5e82ac-a394-4e25-87f6-0a64fc6bd419	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
550f782f-fcfa-4fad-b319-22121075e834	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
f9423160-6ec2-4bd5-80f9-504fcd76f5ff	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
e2fb35cf-4c6d-440b-a0fd-27da1120da16	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	1	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
c7777fa2-95c3-46a2-b728-a47ee2add286	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	2	0.563	339dee6f-1d8f-482c-8465-a87d2650af5e
762bd059-e282-4d3f-bad4-e1f9bea38e26	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
1635eccc-0b8d-4c8d-9fd1-7a36c7db7094	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	4	0.563	339dee6f-1d8f-482c-8465-a87d2650af5e
b4e77ead-538a-4803-b271-93895cfd67b8	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
42f24ca6-2b1d-4d3b-85cc-6590b4eb0d38	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	1	0.138	339dee6f-1d8f-482c-8465-a87d2650af5e
b9f877a5-fa5d-433a-a2ca-a4cb0989beb7	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	2	0.166	339dee6f-1d8f-482c-8465-a87d2650af5e
ad5cb7c3-8017-4c70-943b-1180f3f92a37	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6c0d80b5-450a-471a-bb81-83bf13cd3a03	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
78f5c2a5-de1f-4b94-81c9-30188f15cf21	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4edfdb43-0963-4437-a89a-ae832c7b6b05	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f9640483-98e6-4479-93e2-eab3dfd760a4	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	2	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
eb831c0f-14da-431e-a021-7d482633c0f7	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
7fd838b7-bfb9-487f-9fb6-b3d9e41af11b	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
74048495-cd67-4cec-8133-88e4d935d030	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
0047bbfd-32cf-4797-b413-91045a1396b8	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b596b69-31a6-4d92-9d0a-e7a100cbb4b0	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
2aa34d31-2dfc-4b0e-bc24-7510fc0afdd7	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	3	1.500	339dee6f-1d8f-482c-8465-a87d2650af5e
b1b7c166-1f19-4955-9441-89e997934f48	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	4	1.500	339dee6f-1d8f-482c-8465-a87d2650af5e
4fbc959b-877e-4b98-9b4f-bd636e0b398d	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
c877afd5-a9d7-44d3-85cd-3e5ca91154c9	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2dbeef44-6633-43da-bcb5-68a5693512d9	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
463b3e80-e3c4-42ff-86d4-824bd7bcd42e	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	6	3	0.897	339dee6f-1d8f-482c-8465-a87d2650af5e
d9d7ba34-991d-4c11-bad3-1a9d2462d6ee	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	6	4	1.656	339dee6f-1d8f-482c-8465-a87d2650af5e
44fb67fb-3884-4d65-84fb-add3344f5429	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	6	5	0.138	339dee6f-1d8f-482c-8465-a87d2650af5e
40fc6a23-b527-45aa-99ba-338f5612fabc	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e8673995-0576-45a8-88f3-2b6c8e05fcc6	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
df209658-6de6-4ae9-9289-e370d270232a	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
49aa2779-c29d-4bc4-81df-bc42be22de45	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b1551d3c-3be4-461b-a918-a10df071b940	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ab45f41d-dd31-4f37-9053-03579050e8aa	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7ab0b06c-ee6e-465f-9dd6-f7a86f090e83	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
31005e98-0353-483a-85b9-e3b7651b2f33	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63361dcb-58e7-4ce7-83e6-473da7311323	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
25d2ed2d-a231-4575-b2b5-2bd6d81b19b8	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cd2bcd62-8341-4a9c-9c63-d3a1a2cea264	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	9	1	0.414	339dee6f-1d8f-482c-8465-a87d2650af5e
a07ad6e3-3e11-43fd-b899-457aec09e710	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	9	2	0.690	339dee6f-1d8f-482c-8465-a87d2650af5e
26fcace1-5129-4c66-9295-28bf70964d77	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	9	3	1.380	339dee6f-1d8f-482c-8465-a87d2650af5e
a10eb398-3208-4643-8a32-b4371a15eb95	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	9	4	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
4879d218-454f-40f1-82ad-96e15900ee86	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	9	5	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
27b08671-b83e-44b3-bac4-a4c6ccd30778	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4cc75327-6ab8-4c4e-9d45-ea55fc85a157	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	10	2	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
3466f930-5138-4ea5-af26-37278d6ad0d0	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	10	3	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
486ba0a9-5214-43e1-94dc-2757baebb4cb	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	10	4	0.552	339dee6f-1d8f-482c-8465-a87d2650af5e
61ca1b16-158e-43b1-a07e-33920cccf839	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	10	5	0.138	339dee6f-1d8f-482c-8465-a87d2650af5e
fa046be1-9d9a-4a09-b7d0-d33a3501f284	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	11	1	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
b643b7df-e2e5-489e-a18b-e5cbec141fad	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	11	2	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
601c0f38-3906-4b08-aa88-1bcc3c18213f	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	11	3	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
01c0483b-9202-4c9c-97bc-11277b28386f	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	11	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
91d227b7-a331-4f25-88fd-bc277bc37b8d	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	11	5	0.188	339dee6f-1d8f-482c-8465-a87d2650af5e
bfb6b859-681a-4efd-91fe-9e2aa9e9c051	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0715a511-ee9e-40a2-ac52-57ba66ec83b1	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	12	2	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
b6cca492-fd86-4c8c-8de0-0d1fce4b4fb8	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	12	3	1.104	339dee6f-1d8f-482c-8465-a87d2650af5e
58111406-97e2-4a5f-938c-b56cd88a258a	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	12	4	1.104	339dee6f-1d8f-482c-8465-a87d2650af5e
3d3ed87e-66c0-4874-8abe-9c723c07b16e	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	12	5	0.173	339dee6f-1d8f-482c-8465-a87d2650af5e
bd7b67e1-8797-4522-9cd9-2ef0bcf17afe	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e3f7139b-62be-4a3c-8d80-f2d040e5ebcf	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b6f3adcb-b560-428e-922d-4afd03635233	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	13	3	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
a91f24c1-3d38-49ee-8f6f-c38b6cdbc9c7	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	13	4	0.994	339dee6f-1d8f-482c-8465-a87d2650af5e
40b08455-4fc7-48fd-8638-187ed7b2fc36	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8a2704c7-57a1-48bb-8b7f-44d095587d1a	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74bd85e2-2155-4cf9-8cca-fd7a3c6ad49c	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7b2eb535-cf44-4804-a7e9-45d10e7e6056	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	14	3	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
03f6843a-fd05-4a3e-85f1-efd3421af37c	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	14	4	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
e0e4099f-78e8-47e6-bb05-18ceb892c0cd	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1b8401c9-5c0a-4f9a-a86a-d2d6667236ef	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b242c86b-db1b-4789-83e2-265cf42342d4	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	15	2	0.276	339dee6f-1d8f-482c-8465-a87d2650af5e
6af75b8f-cb42-42f6-9b4a-5e15ae0798ff	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3a897b34-64c4-4163-8f0e-70743846e042	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
14994130-7c7f-49ad-b7e6-3364250d0ab0	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b811acd-09f3-47d7-af13-99d9d6839adf	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a229e411-d3b2-415f-9f63-ac5994ac0077	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
86315291-fda0-4be0-84c2-a157378859e6	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	16	3	0.166	339dee6f-1d8f-482c-8465-a87d2650af5e
94987548-2e60-404d-8de6-eb9ce65791a2	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
47ee7ed9-179d-43c7-a4fd-32ac92a5a197	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e7d8d865-2652-4bb2-b157-503e793914b5	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6600115-0bd1-4107-9761-8309af09da13	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
52097305-8190-4e1c-adcd-624ad251131c	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	17	3	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
e5d9bf64-f5c5-4e25-90df-a7bb3c869565	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5d41dc34-a36b-4816-87cf-f7a5012af1bb	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b48881f-d54f-4226-a786-7c913b03cd5c	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fad2a271-7c09-435a-9fb3-af410dd3e2f6	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f590ec01-e457-4a7f-816a-33030842e703	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7e06c06b-ca9a-4af4-b14e-168e4b945fbb	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	18	4	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
3080823a-ac67-40f4-9572-f0bfbcc2b201	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
15047770-f9c4-4522-ac79-4ffcabff4772	7d16a30f-979c-44c3-8784-1045661fa333	1	1	0.662	339dee6f-1d8f-482c-8465-a87d2650af5e
fb490b45-63e7-4254-a04c-914deffff260	7d16a30f-979c-44c3-8784-1045661fa333	1	2	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
79ceaef1-e105-40b9-89a5-aa772a052086	7d16a30f-979c-44c3-8784-1045661fa333	1	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
e388a338-bdba-4140-97c8-51732fbce78a	7d16a30f-979c-44c3-8784-1045661fa333	1	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
89264f23-3e2b-49c4-bd29-2bdf180767e1	7d16a30f-979c-44c3-8784-1045661fa333	1	5	0.441	339dee6f-1d8f-482c-8465-a87d2650af5e
aa383db2-6a83-4bc9-ad1a-5dab970b253a	7d16a30f-979c-44c3-8784-1045661fa333	2	1	0.662	339dee6f-1d8f-482c-8465-a87d2650af5e
221eaaee-fe62-4a39-b90e-f27306829ebc	7d16a30f-979c-44c3-8784-1045661fa333	2	2	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
03daff15-110a-4c3c-b8cd-786965530267	7d16a30f-979c-44c3-8784-1045661fa333	2	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
2ae5f382-ae81-4f1e-a265-ebc1570db437	7d16a30f-979c-44c3-8784-1045661fa333	2	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
3c3d9a28-cbd1-4d34-8c79-735d7cf58604	7d16a30f-979c-44c3-8784-1045661fa333	2	5	0.441	339dee6f-1d8f-482c-8465-a87d2650af5e
279471c4-87f8-4a7a-8153-8df92e5632f0	7d16a30f-979c-44c3-8784-1045661fa333	3	1	0.846	339dee6f-1d8f-482c-8465-a87d2650af5e
c378c04e-0983-4646-bf1f-4b7d3e8ed089	7d16a30f-979c-44c3-8784-1045661fa333	3	2	0.423	339dee6f-1d8f-482c-8465-a87d2650af5e
0d776e12-3af4-41fd-86cc-3ab7aa17098d	7d16a30f-979c-44c3-8784-1045661fa333	3	3	0.423	339dee6f-1d8f-482c-8465-a87d2650af5e
3a05765a-6d28-4a9d-9cdf-28e54597d2d0	7d16a30f-979c-44c3-8784-1045661fa333	3	4	0.423	339dee6f-1d8f-482c-8465-a87d2650af5e
6d6d0685-a4cc-47ff-b6b2-1f3230498d3d	7d16a30f-979c-44c3-8784-1045661fa333	3	5	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
40a4e1da-d501-4307-b44d-c9cfbeffb4b3	7d16a30f-979c-44c3-8784-1045661fa333	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aeebaf27-fa0f-4ec1-ba54-cf0e9e5d6fd0	7d16a30f-979c-44c3-8784-1045661fa333	4	2	0.441	339dee6f-1d8f-482c-8465-a87d2650af5e
099bf955-86a4-40b3-9673-0597041b2a4a	7d16a30f-979c-44c3-8784-1045661fa333	4	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
ef736587-998d-4dbc-966e-62cafdd093a3	7d16a30f-979c-44c3-8784-1045661fa333	4	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
14eaab51-66cf-435b-a53c-8cdba9f5e86a	7d16a30f-979c-44c3-8784-1045661fa333	4	5	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
486e440b-4d83-465d-b5b3-3bfe04efeebb	7d16a30f-979c-44c3-8784-1045661fa333	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8a31d48f-806f-46ea-81ee-dac01eca68a1	7d16a30f-979c-44c3-8784-1045661fa333	5	2	1.324	339dee6f-1d8f-482c-8465-a87d2650af5e
f38cafec-89bb-4134-89dc-b5cdcd333bcb	7d16a30f-979c-44c3-8784-1045661fa333	5	3	2.648	339dee6f-1d8f-482c-8465-a87d2650af5e
95428392-032e-4ec6-b40b-cee67739ddc9	7d16a30f-979c-44c3-8784-1045661fa333	5	4	2.648	339dee6f-1d8f-482c-8465-a87d2650af5e
262c6dc0-bc69-4b5f-8ac8-6e50d20e8575	7d16a30f-979c-44c3-8784-1045661fa333	5	5	0.662	339dee6f-1d8f-482c-8465-a87d2650af5e
aa88afe3-1fa4-4a3d-93ab-a3fb4a04e90a	7d16a30f-979c-44c3-8784-1045661fa333	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
363c1dde-c2b0-4c01-b36d-fae39528bab4	7d16a30f-979c-44c3-8784-1045661fa333	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3d8130a4-edfe-483f-b128-3376279b475b	7d16a30f-979c-44c3-8784-1045661fa333	6	3	5.497	339dee6f-1d8f-482c-8465-a87d2650af5e
f68f73ef-7359-459e-8d0f-f1a5a08d2289	7d16a30f-979c-44c3-8784-1045661fa333	6	4	6.343	339dee6f-1d8f-482c-8465-a87d2650af5e
f4d1d68f-4343-470c-b436-6dd76cc0c17d	7d16a30f-979c-44c3-8784-1045661fa333	6	5	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
97d97c09-382c-4b7f-afa2-027f65769984	7d16a30f-979c-44c3-8784-1045661fa333	7	1	0.740	339dee6f-1d8f-482c-8465-a87d2650af5e
a76a9f19-b30d-47eb-9862-fc2c901021a3	7d16a30f-979c-44c3-8784-1045661fa333	7	2	3.806	339dee6f-1d8f-482c-8465-a87d2650af5e
10f59120-5c6a-4d82-a728-7532ba9f1669	7d16a30f-979c-44c3-8784-1045661fa333	7	3	2.114	339dee6f-1d8f-482c-8465-a87d2650af5e
a769a25e-10ce-4006-ad38-3fed4456d0ef	7d16a30f-979c-44c3-8784-1045661fa333	7	4	1.057	339dee6f-1d8f-482c-8465-a87d2650af5e
d450e8a0-e9b5-4d4b-a2bb-a95e6cd3cf6c	7d16a30f-979c-44c3-8784-1045661fa333	7	5	0.423	339dee6f-1d8f-482c-8465-a87d2650af5e
2f332867-6b3e-4a41-8ad8-425a5763f7c8	7d16a30f-979c-44c3-8784-1045661fa333	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a4f7262f-5f6d-4c7e-8933-06c10ea5c35a	7d16a30f-979c-44c3-8784-1045661fa333	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
98eebecb-bbf4-4620-a0a6-dc5432d5a8aa	7d16a30f-979c-44c3-8784-1045661fa333	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
83537e41-0c33-4586-ba69-6af9dcf2005e	7d16a30f-979c-44c3-8784-1045661fa333	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32a75015-6bf1-43a1-81b3-9e4346b8ab5c	7d16a30f-979c-44c3-8784-1045661fa333	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7102b154-45c4-4742-b79c-02ef777cc5d3	7d16a30f-979c-44c3-8784-1045661fa333	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
96338988-de75-474c-8c06-17a4e2b68a75	7d16a30f-979c-44c3-8784-1045661fa333	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c9065e4f-4269-4c4b-8b87-e4557ed9e7d8	7d16a30f-979c-44c3-8784-1045661fa333	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d3ea6d97-e5df-469d-905a-6378b82f990c	7d16a30f-979c-44c3-8784-1045661fa333	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
eeb7107b-a172-417b-8d7d-0b4707f839d9	7d16a30f-979c-44c3-8784-1045661fa333	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
110d7f99-9125-4978-8a7e-a4689b801fe0	7d16a30f-979c-44c3-8784-1045661fa333	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7be60008-140d-40f2-9de0-1f5ae6bdf440	7d16a30f-979c-44c3-8784-1045661fa333	10	2	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
b6543989-0a4f-4d1e-896d-da6a0d65e9a8	7d16a30f-979c-44c3-8784-1045661fa333	10	3	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
a1ea4e21-e99f-474d-8525-df1201b8c4a3	7d16a30f-979c-44c3-8784-1045661fa333	10	4	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
93e140a7-90e4-4677-97d3-18280944b588	7d16a30f-979c-44c3-8784-1045661fa333	10	5	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
202e09eb-e526-4e5c-9e64-84b0d524c923	7d16a30f-979c-44c3-8784-1045661fa333	11	1	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
3917b92d-662d-4728-9bd4-69a7183e86f5	7d16a30f-979c-44c3-8784-1045661fa333	11	2	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
89888b68-5318-48a8-acfa-ccf1c7527302	7d16a30f-979c-44c3-8784-1045661fa333	11	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
9eed4f1a-4a94-42e1-920a-66cbc788c2c0	7d16a30f-979c-44c3-8784-1045661fa333	11	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
fd873277-faae-4fae-994d-7138d5c2b74f	7d16a30f-979c-44c3-8784-1045661fa333	11	5	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
2595f2a4-e896-42cc-b34d-2c10db161df3	7d16a30f-979c-44c3-8784-1045661fa333	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2a2fea25-2897-470c-a4f3-99f656ed337a	7d16a30f-979c-44c3-8784-1045661fa333	12	2	1.691	339dee6f-1d8f-482c-8465-a87d2650af5e
6c094229-fef1-431b-80b6-388b0e2df8b3	7d16a30f-979c-44c3-8784-1045661fa333	12	3	3.383	339dee6f-1d8f-482c-8465-a87d2650af5e
3b08048a-76b7-46b2-8799-a4bb87f7960e	7d16a30f-979c-44c3-8784-1045661fa333	12	4	4.228	339dee6f-1d8f-482c-8465-a87d2650af5e
8fb20f2d-9881-422f-91d9-19ff4dbd33db	7d16a30f-979c-44c3-8784-1045661fa333	12	5	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
74754858-e442-45d0-8110-cd40061e47ca	7d16a30f-979c-44c3-8784-1045661fa333	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d261714c-a6e9-4b9a-9e9b-56aa67423fb1	7d16a30f-979c-44c3-8784-1045661fa333	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bbf555da-1d03-4518-90e5-56612f507e1c	7d16a30f-979c-44c3-8784-1045661fa333	13	3	2.537	339dee6f-1d8f-482c-8465-a87d2650af5e
b41bf993-246a-4f9b-a3c1-012805ee1a34	7d16a30f-979c-44c3-8784-1045661fa333	13	4	4.228	339dee6f-1d8f-482c-8465-a87d2650af5e
91e46c34-dc90-4b92-9a26-254b121ff185	7d16a30f-979c-44c3-8784-1045661fa333	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
eafef1b8-3e4e-4d49-b46a-b59c4417790a	7d16a30f-979c-44c3-8784-1045661fa333	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
207eefc6-a4d7-4868-b7d8-26a4be263323	7d16a30f-979c-44c3-8784-1045661fa333	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
83569401-cf72-4b37-9d1b-88577a50ae5a	7d16a30f-979c-44c3-8784-1045661fa333	14	3	0.634	339dee6f-1d8f-482c-8465-a87d2650af5e
e3d76fdc-fcdf-4757-95f4-d3f49545cc94	7d16a30f-979c-44c3-8784-1045661fa333	14	4	0.634	339dee6f-1d8f-482c-8465-a87d2650af5e
35bb595a-d112-40e4-b42b-04f0d0118d3f	7d16a30f-979c-44c3-8784-1045661fa333	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9e180dba-371c-47f6-9db6-d81c3fbef8db	7d16a30f-979c-44c3-8784-1045661fa333	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9d33993a-6ada-43e1-8741-f8f8da881308	7d16a30f-979c-44c3-8784-1045661fa333	15	2	0.476	339dee6f-1d8f-482c-8465-a87d2650af5e
48e1f8c1-b46c-4773-a84d-697f08697b46	7d16a30f-979c-44c3-8784-1045661fa333	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cff39ef-7718-4730-922e-9c78b577e8a7	7d16a30f-979c-44c3-8784-1045661fa333	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
30fbd4aa-8a11-49f0-aff5-682833d107ae	7d16a30f-979c-44c3-8784-1045661fa333	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8c5195fd-bc51-44a1-a35f-542208a045a5	7d16a30f-979c-44c3-8784-1045661fa333	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
70b73692-0c5b-47c1-9ecf-d2fd2be83a34	7d16a30f-979c-44c3-8784-1045661fa333	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8d7f9bfd-01aa-4cc9-a856-b4c7cf64b268	7d16a30f-979c-44c3-8784-1045661fa333	16	3	0.951	339dee6f-1d8f-482c-8465-a87d2650af5e
1a8045d0-2b57-455d-a12a-d6ee34f2d407	7d16a30f-979c-44c3-8784-1045661fa333	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d00e0613-63b6-4ecb-80de-91e226cd5ac9	7d16a30f-979c-44c3-8784-1045661fa333	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b8e3627-a8ff-49cc-8c88-6b31920f68c0	7d16a30f-979c-44c3-8784-1045661fa333	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8ef934e1-14ab-442e-b6e1-2e692429608f	7d16a30f-979c-44c3-8784-1045661fa333	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fb32d062-77f9-44c6-8c6f-e3ee3720c379	7d16a30f-979c-44c3-8784-1045661fa333	17	3	3.171	339dee6f-1d8f-482c-8465-a87d2650af5e
5b6df7c2-4318-478e-8f37-aa8aa89adef8	7d16a30f-979c-44c3-8784-1045661fa333	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63492d0c-a0d3-4470-a03a-621c44f0cd64	7d16a30f-979c-44c3-8784-1045661fa333	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6bdcb3d5-bc81-4d3c-8ac4-cffc345dcb8d	7d16a30f-979c-44c3-8784-1045661fa333	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
99630b2b-b96b-426f-8baf-08b5beafbc5d	7d16a30f-979c-44c3-8784-1045661fa333	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
202727ba-90aa-4780-b1b3-1b835a98cf14	7d16a30f-979c-44c3-8784-1045661fa333	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
16494339-9ef2-4045-aa34-443143c9308c	7d16a30f-979c-44c3-8784-1045661fa333	18	4	0.423	339dee6f-1d8f-482c-8465-a87d2650af5e
991309f6-e768-479b-b23e-e42a60e4854c	7d16a30f-979c-44c3-8784-1045661fa333	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c59eef33-3990-48c8-9a6a-895ac0ba1614	e335d212-f193-47a7-8729-8e81feffec05	1	1	0.414	339dee6f-1d8f-482c-8465-a87d2650af5e
6c4c9cd6-a517-4e0c-860e-551f7b4db1f3	e335d212-f193-47a7-8729-8e81feffec05	1	2	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
3ef5a74a-53b8-4df4-a605-f9cd22051495	e335d212-f193-47a7-8729-8e81feffec05	1	3	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
b85d5a15-42d8-4b33-8208-d0fe1ed9cf6b	e335d212-f193-47a7-8729-8e81feffec05	1	4	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
97124ae7-08d2-4b87-a6f5-1fc037448d36	e335d212-f193-47a7-8729-8e81feffec05	1	5	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
9a774801-b18f-41ba-a545-25a810db786a	e335d212-f193-47a7-8729-8e81feffec05	2	1	0.414	339dee6f-1d8f-482c-8465-a87d2650af5e
0ce74551-af5b-460b-a60e-5df468773695	e335d212-f193-47a7-8729-8e81feffec05	2	2	0.621	339dee6f-1d8f-482c-8465-a87d2650af5e
5370560d-1e15-4dc6-9813-c6fb23c811f0	e335d212-f193-47a7-8729-8e81feffec05	2	3	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
f05e1c78-d9d4-4262-8e22-d20f7ff234e7	e335d212-f193-47a7-8729-8e81feffec05	2	4	0.621	339dee6f-1d8f-482c-8465-a87d2650af5e
40e48b6a-8844-4dbd-be3e-30eb7a6499b4	e335d212-f193-47a7-8729-8e81feffec05	2	5	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
3a066c93-c2b4-491b-ba4e-db94bc100a13	e335d212-f193-47a7-8729-8e81feffec05	3	1	0.170	339dee6f-1d8f-482c-8465-a87d2650af5e
acca9ccb-603b-42db-9197-f3d2c522be56	e335d212-f193-47a7-8729-8e81feffec05	3	2	0.204	339dee6f-1d8f-482c-8465-a87d2650af5e
49577e8b-fdd2-48e5-b97f-8c028dfaae65	e335d212-f193-47a7-8729-8e81feffec05	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
60b48209-0df4-4f1f-836b-1a9e10df8c4b	e335d212-f193-47a7-8729-8e81feffec05	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
92a2fd65-b87b-46b2-8780-204662a4498c	e335d212-f193-47a7-8729-8e81feffec05	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
210954e4-9b84-428c-9466-85e310d22f5f	e335d212-f193-47a7-8729-8e81feffec05	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
423159d9-d2ee-45ce-9c6f-c44b3da90110	e335d212-f193-47a7-8729-8e81feffec05	4	2	0.414	339dee6f-1d8f-482c-8465-a87d2650af5e
9f003c29-0e2c-41a8-8c6d-44f5f7953724	e335d212-f193-47a7-8729-8e81feffec05	4	3	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
fa6f941e-1c8c-4156-8099-248c7d094d6e	e335d212-f193-47a7-8729-8e81feffec05	4	4	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
82b4f3e5-081a-41e7-b05d-721024e7c379	e335d212-f193-47a7-8729-8e81feffec05	4	5	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
3980ced1-d948-48ee-811a-811954cb6fdb	e335d212-f193-47a7-8729-8e81feffec05	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dd8d2087-37dd-43a0-b1cd-4389ce917567	e335d212-f193-47a7-8729-8e81feffec05	5	2	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
a9d35d10-d5fb-49e9-90aa-c6426adf2891	e335d212-f193-47a7-8729-8e81feffec05	5	3	1.657	339dee6f-1d8f-482c-8465-a87d2650af5e
ad514b7a-c72f-4d55-a062-637453e793bc	e335d212-f193-47a7-8729-8e81feffec05	5	4	1.657	339dee6f-1d8f-482c-8465-a87d2650af5e
556cd2d3-b91c-4c4d-969a-de6dcbc83f81	e335d212-f193-47a7-8729-8e81feffec05	5	5	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
867f0ac0-9f5c-4792-90e8-770a6d45cb3a	e335d212-f193-47a7-8729-8e81feffec05	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3ea2f449-66c4-4a3e-a65b-df5b7227cfa7	e335d212-f193-47a7-8729-8e81feffec05	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6f01c4ed-3252-4411-96b3-ffeeb1af774c	e335d212-f193-47a7-8729-8e81feffec05	6	3	1.107	339dee6f-1d8f-482c-8465-a87d2650af5e
0ef157f7-e7d6-4304-9187-2db1b2972e6b	e335d212-f193-47a7-8729-8e81feffec05	6	4	2.044	339dee6f-1d8f-482c-8465-a87d2650af5e
4101bd6c-56f6-4b62-9822-0bd95e0f7723	e335d212-f193-47a7-8729-8e81feffec05	6	5	0.170	339dee6f-1d8f-482c-8465-a87d2650af5e
31e2566b-6548-4f73-abd3-56099f918faa	e335d212-f193-47a7-8729-8e81feffec05	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
df5bd441-a270-4db0-8329-70caeec231ed	e335d212-f193-47a7-8729-8e81feffec05	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
01401e77-f016-43e9-82c6-acf5d0e10089	e335d212-f193-47a7-8729-8e81feffec05	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
883a34f0-f83a-47e6-9ace-9a942df7f447	e335d212-f193-47a7-8729-8e81feffec05	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
793fd5e4-41c6-4332-8226-81c2039a1959	e335d212-f193-47a7-8729-8e81feffec05	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
945a981e-2be1-4b88-9a54-c15c22625785	e335d212-f193-47a7-8729-8e81feffec05	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a9a5746-dab4-4f81-ad0e-e0eddd1185cd	e335d212-f193-47a7-8729-8e81feffec05	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0f105c8-8215-403a-bbd2-e58278f5676d	e335d212-f193-47a7-8729-8e81feffec05	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
27877ade-5a52-44da-9911-cecd8807f9d5	e335d212-f193-47a7-8729-8e81feffec05	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
340db787-cdd1-4788-bacb-072ee52fbee5	e335d212-f193-47a7-8729-8e81feffec05	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
13d08623-1131-408e-92a1-462c51497c16	e335d212-f193-47a7-8729-8e81feffec05	9	1	0.511	339dee6f-1d8f-482c-8465-a87d2650af5e
e092c786-78e0-4eb3-aed7-822add16d21a	e335d212-f193-47a7-8729-8e81feffec05	9	2	0.852	339dee6f-1d8f-482c-8465-a87d2650af5e
ba0cbec9-4cf4-45d5-927a-00429985d0df	e335d212-f193-47a7-8729-8e81feffec05	9	3	1.703	339dee6f-1d8f-482c-8465-a87d2650af5e
76387ab6-fa62-4190-ad36-dfe85e4ade57	e335d212-f193-47a7-8729-8e81feffec05	9	4	0.681	339dee6f-1d8f-482c-8465-a87d2650af5e
1bf2347d-dace-4a38-8294-a7f4d8f7bdaa	e335d212-f193-47a7-8729-8e81feffec05	9	5	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
a33f3032-0281-4939-842f-12c64366b639	e335d212-f193-47a7-8729-8e81feffec05	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f83e5b07-4ea0-4ee4-a720-b4ba39e8051d	e335d212-f193-47a7-8729-8e81feffec05	10	2	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
eb40f2a1-a282-4c81-b72c-7f97dc81c68a	e335d212-f193-47a7-8729-8e81feffec05	10	3	0.681	339dee6f-1d8f-482c-8465-a87d2650af5e
d9b6abe9-85c6-495c-9047-faed82ebc29b	e335d212-f193-47a7-8729-8e81feffec05	10	4	0.681	339dee6f-1d8f-482c-8465-a87d2650af5e
5da4af2d-c0da-4025-a9f7-4f5a9a4a45d8	e335d212-f193-47a7-8729-8e81feffec05	10	5	0.170	339dee6f-1d8f-482c-8465-a87d2650af5e
dbc13354-1361-4ea5-a0a0-96dfae15bc74	e335d212-f193-47a7-8729-8e81feffec05	11	1	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
52736c97-5a7a-4d7d-a8cf-09c5d1ebce4b	e335d212-f193-47a7-8729-8e81feffec05	11	2	0.331	339dee6f-1d8f-482c-8465-a87d2650af5e
25c11b80-d23a-466a-8b4b-3ee8c67a43a8	e335d212-f193-47a7-8729-8e81feffec05	11	3	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
6c533fe5-b325-4d6e-8e0c-2316287868cf	e335d212-f193-47a7-8729-8e81feffec05	11	4	0.828	339dee6f-1d8f-482c-8465-a87d2650af5e
74079972-baa6-4bb7-94b3-8e8f6075f893	e335d212-f193-47a7-8729-8e81feffec05	11	5	0.207	339dee6f-1d8f-482c-8465-a87d2650af5e
30d32274-ab3d-455d-b966-bd63026a3b3d	e335d212-f193-47a7-8729-8e81feffec05	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
732ab10f-fcb6-4766-9300-27de7a32d7e1	e335d212-f193-47a7-8729-8e81feffec05	12	2	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
2e87aa91-66c2-442c-bb0e-ac6921454c23	e335d212-f193-47a7-8729-8e81feffec05	12	3	1.363	339dee6f-1d8f-482c-8465-a87d2650af5e
75bfbbb1-47af-4adf-a71e-d6e9e34f56df	e335d212-f193-47a7-8729-8e81feffec05	12	4	1.363	339dee6f-1d8f-482c-8465-a87d2650af5e
479d85f5-ce23-4c90-94c9-b32281eb5d74	e335d212-f193-47a7-8729-8e81feffec05	12	5	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
e366fb07-1217-4867-938a-e6c215608fdb	e335d212-f193-47a7-8729-8e81feffec05	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
664810bc-7e67-4615-8721-0689844fd61b	e335d212-f193-47a7-8729-8e81feffec05	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bd7e1e61-c5da-4033-af9c-0281700902d5	e335d212-f193-47a7-8729-8e81feffec05	13	3	1.022	339dee6f-1d8f-482c-8465-a87d2650af5e
26abeb7d-efbb-46bb-b2eb-389f52c3be72	e335d212-f193-47a7-8729-8e81feffec05	13	4	1.227	339dee6f-1d8f-482c-8465-a87d2650af5e
e04d7161-0ca3-4091-8f70-2a93f0cf276c	e335d212-f193-47a7-8729-8e81feffec05	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
34adef31-094c-41d7-b30f-002e16fa38e7	e335d212-f193-47a7-8729-8e81feffec05	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
99b4f73a-19fc-4c0c-b87b-fb02b523a6f4	e335d212-f193-47a7-8729-8e81feffec05	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c6d7a1e3-8074-4c60-a5af-b1f9224b0842	e335d212-f193-47a7-8729-8e81feffec05	14	3	0.128	339dee6f-1d8f-482c-8465-a87d2650af5e
f1a3175b-008e-4ad3-9308-39978e73f423	e335d212-f193-47a7-8729-8e81feffec05	14	4	0.128	339dee6f-1d8f-482c-8465-a87d2650af5e
3a8b957a-8bed-42d6-9542-8f86f4add068	e335d212-f193-47a7-8729-8e81feffec05	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0ec0efd0-34aa-448f-9856-f1e7db937e7b	e335d212-f193-47a7-8729-8e81feffec05	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a203faca-fc0a-401e-a81e-c50c219464aa	e335d212-f193-47a7-8729-8e81feffec05	15	2	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
02f5c451-0598-4e21-bdd5-c6c8bba1150e	e335d212-f193-47a7-8729-8e81feffec05	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ef509bea-7fa4-4ea9-a4e1-1258f33a3553	e335d212-f193-47a7-8729-8e81feffec05	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e645a978-471e-4918-a0c3-65a3aa07f0cc	e335d212-f193-47a7-8729-8e81feffec05	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4c949b00-2b66-4fec-86bf-5d0f66d95cca	e335d212-f193-47a7-8729-8e81feffec05	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a673f59d-ab20-4180-adbe-4d1a85ad6f3c	e335d212-f193-47a7-8729-8e81feffec05	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9df23a78-bef3-4b2b-8219-b4596a94a1a0	e335d212-f193-47a7-8729-8e81feffec05	16	3	0.204	339dee6f-1d8f-482c-8465-a87d2650af5e
20b1c83c-9b7d-4d13-bc0c-30f14e93c698	e335d212-f193-47a7-8729-8e81feffec05	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a62614e7-23c9-45ce-8aff-349efb3525dd	e335d212-f193-47a7-8729-8e81feffec05	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2777da8c-4b3e-48b2-883e-b3b4b5c7da46	e335d212-f193-47a7-8729-8e81feffec05	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a6713ec9-02e7-48a0-854c-1739d5e2495d	e335d212-f193-47a7-8729-8e81feffec05	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c504b5d5-aa55-4e55-a7bc-f28456f306bf	e335d212-f193-47a7-8729-8e81feffec05	17	3	0.256	339dee6f-1d8f-482c-8465-a87d2650af5e
045cb156-0166-46df-b158-196e8f0ab1da	e335d212-f193-47a7-8729-8e81feffec05	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ee4139c2-3045-4059-8a2e-d6b8aa1837e8	e335d212-f193-47a7-8729-8e81feffec05	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9366584c-d658-4cb3-beda-94002745a202	e335d212-f193-47a7-8729-8e81feffec05	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
45052451-7f92-4c3b-9afc-68b0e522c18c	e335d212-f193-47a7-8729-8e81feffec05	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b313d50d-d6a6-49c0-ba2c-9920a025b75d	e335d212-f193-47a7-8729-8e81feffec05	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d24106d9-b83c-4228-be53-21cba5090e9a	e335d212-f193-47a7-8729-8e81feffec05	18	4	0.256	339dee6f-1d8f-482c-8465-a87d2650af5e
ca6f922f-e2c3-4390-b17a-cf7eab06561a	e335d212-f193-47a7-8729-8e81feffec05	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
797675be-1862-4a6d-a857-5e2978f25c8c	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
f44ba72f-0ef3-4101-bfd1-cceb3f24edc1	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
37161f72-d248-4447-bfd4-220400f56814	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f1fcf227-78fc-429f-8ab8-1303947e9ed9	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c850686b-a256-4239-aa99-3cce03425aff	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
d7be0bdc-52f2-48f6-ac83-ef7df31c719b	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
2a9719fa-13bb-4473-96c2-ad3ddf105371	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
32a339dd-ab14-47d6-911b-4f839104ef5c	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8012c715-29d1-48a6-bc6a-a3120f02b462	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
6b932dc7-2625-4661-82f2-ff90bcbb2070	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
08b2777b-bb51-42bc-a8e1-6af92a2bc3cc	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	1	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
a35a672d-e23a-4894-a6c4-cf19a2b34dc7	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	2	0.409	339dee6f-1d8f-482c-8465-a87d2650af5e
9e5471c0-3bbf-4fef-8b68-73f287c55e5d	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
72a1ed31-b425-419f-b5d3-5709bc02bafe	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
de5972f3-7870-46dd-b8ae-8c9f2257d9f4	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b9cf78f5-0040-4477-a85f-55a4ae75085d	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a2f89b7b-1b3a-4620-8d61-37e963a3c903	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	2	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
73b4cafd-d380-4359-9e8c-86811ff7189e	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
46427cf3-5310-4983-9152-ebaa77f19725	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6da5f55-3e79-43d6-8e30-069dbf423eca	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
653dac9c-a240-480c-b677-c81632eabe79	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
abdaf695-474b-44b3-81ba-85284f0d6b52	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c27f6c7a-164e-4941-a8ae-3a768ba0596d	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	3	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fa9ccdb6-84b9-4379-82f7-c4db12f4376b	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	4	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
48bf8a69-76a9-4564-8703-e8adbbac9e72	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
6249da5c-2329-4f61-8b4e-738a3459fbb2	cd10c6b3-44f9-42dd-9c13-de9922f60581	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0ce5b07a-2c60-4435-a9eb-f5c272f7da13	cd10c6b3-44f9-42dd-9c13-de9922f60581	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7718d514-0e38-45b4-b48e-dd4357c6f71d	cd10c6b3-44f9-42dd-9c13-de9922f60581	6	3	2.217	339dee6f-1d8f-482c-8465-a87d2650af5e
87bc223c-53bb-4936-a4eb-765dd3a7a913	cd10c6b3-44f9-42dd-9c13-de9922f60581	6	4	4.093	339dee6f-1d8f-482c-8465-a87d2650af5e
b1921f3c-5692-4ff8-8f49-554b68c5e68d	cd10c6b3-44f9-42dd-9c13-de9922f60581	6	5	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
1467b77a-185b-416e-8ce8-c3d6e51cfd72	cd10c6b3-44f9-42dd-9c13-de9922f60581	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9167c6d0-044b-4699-86fa-ceb7c2d525bd	cd10c6b3-44f9-42dd-9c13-de9922f60581	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
002e4c33-2484-4a5f-912f-866231b556f9	cd10c6b3-44f9-42dd-9c13-de9922f60581	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5bf146ad-b9a9-46e2-a302-1831c5ff0f62	cd10c6b3-44f9-42dd-9c13-de9922f60581	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b9d08bc-9c21-413a-b94b-862546601ae9	cd10c6b3-44f9-42dd-9c13-de9922f60581	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c8e575a3-a6b3-4b7f-9e8d-96d281c7e1f7	cd10c6b3-44f9-42dd-9c13-de9922f60581	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
262d1642-bf32-4705-88a5-423541c4f631	cd10c6b3-44f9-42dd-9c13-de9922f60581	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4e39185e-ce3b-4ec8-90f7-f541f60ecddb	cd10c6b3-44f9-42dd-9c13-de9922f60581	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a37874c0-f510-4527-b114-d3170b114050	cd10c6b3-44f9-42dd-9c13-de9922f60581	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
72b8806f-adaa-4106-8e63-60029a7c2fc3	cd10c6b3-44f9-42dd-9c13-de9922f60581	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f5da66c6-3e30-49ca-8241-3ec06c0261bf	cd10c6b3-44f9-42dd-9c13-de9922f60581	9	1	1.023	339dee6f-1d8f-482c-8465-a87d2650af5e
c74a4dba-f075-49f9-a33a-7cad8d12e339	cd10c6b3-44f9-42dd-9c13-de9922f60581	9	2	1.705	339dee6f-1d8f-482c-8465-a87d2650af5e
8ca64181-25b3-44c0-9150-1d1c8ad6abf6	cd10c6b3-44f9-42dd-9c13-de9922f60581	9	3	3.411	339dee6f-1d8f-482c-8465-a87d2650af5e
3f5f1067-f15e-42d3-86e6-aba40ebb0f0e	cd10c6b3-44f9-42dd-9c13-de9922f60581	9	4	1.364	339dee6f-1d8f-482c-8465-a87d2650af5e
613b0df3-2bc6-4f58-a47a-bc34d8774a85	cd10c6b3-44f9-42dd-9c13-de9922f60581	9	5	0.682	339dee6f-1d8f-482c-8465-a87d2650af5e
0f3a8685-acf9-4e6a-bfe1-5639f390ef41	cd10c6b3-44f9-42dd-9c13-de9922f60581	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
472b7fc2-5583-4b69-8707-bab2f16d0aed	cd10c6b3-44f9-42dd-9c13-de9922f60581	10	2	0.682	339dee6f-1d8f-482c-8465-a87d2650af5e
503cf61a-f9b1-4b17-8474-cd450ae2039e	cd10c6b3-44f9-42dd-9c13-de9922f60581	10	3	1.364	339dee6f-1d8f-482c-8465-a87d2650af5e
94c4a068-ab23-4d97-aa79-4ef7fb70e5ce	cd10c6b3-44f9-42dd-9c13-de9922f60581	10	4	1.364	339dee6f-1d8f-482c-8465-a87d2650af5e
fed99294-ca22-4020-8c7b-2cb667ea34d1	cd10c6b3-44f9-42dd-9c13-de9922f60581	10	5	0.341	339dee6f-1d8f-482c-8465-a87d2650af5e
2d40b4d0-e190-4981-b27f-a695c16b5d77	cd10c6b3-44f9-42dd-9c13-de9922f60581	11	1	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
d15ef1a7-9078-408b-9ebc-02821590ea5d	cd10c6b3-44f9-42dd-9c13-de9922f60581	11	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
cfe0fb9a-ad56-452b-93e5-7e31728ba286	cd10c6b3-44f9-42dd-9c13-de9922f60581	11	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0a19efc3-9e3c-4283-b1bb-01a163370011	cd10c6b3-44f9-42dd-9c13-de9922f60581	11	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2ade625d-4a73-4b15-b3f8-cb604ac6c635	cd10c6b3-44f9-42dd-9c13-de9922f60581	11	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
b371a7ff-8342-42b5-b512-413f8f9823fe	cd10c6b3-44f9-42dd-9c13-de9922f60581	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1c400248-bf10-47eb-9be5-921e041ffb46	cd10c6b3-44f9-42dd-9c13-de9922f60581	12	2	0.682	339dee6f-1d8f-482c-8465-a87d2650af5e
85cb62ac-d113-4e5a-bb1d-cff51792fe37	cd10c6b3-44f9-42dd-9c13-de9922f60581	12	3	2.729	339dee6f-1d8f-482c-8465-a87d2650af5e
3908fe48-1b84-4af5-b2e8-f96075fbd5bb	cd10c6b3-44f9-42dd-9c13-de9922f60581	12	4	2.729	339dee6f-1d8f-482c-8465-a87d2650af5e
90e733ab-cc9d-4298-a82e-79b48a6aadc2	cd10c6b3-44f9-42dd-9c13-de9922f60581	12	5	0.426	339dee6f-1d8f-482c-8465-a87d2650af5e
6b75416c-35ad-4335-b67a-39861f0aa404	cd10c6b3-44f9-42dd-9c13-de9922f60581	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d8064092-0299-47f2-8cdf-3b7a87df924c	cd10c6b3-44f9-42dd-9c13-de9922f60581	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d0c53074-9783-46d8-814a-18f8afbd8251	cd10c6b3-44f9-42dd-9c13-de9922f60581	13	3	2.047	339dee6f-1d8f-482c-8465-a87d2650af5e
cdf9cad9-b847-4522-9015-38cf8ddbd960	cd10c6b3-44f9-42dd-9c13-de9922f60581	13	4	2.456	339dee6f-1d8f-482c-8465-a87d2650af5e
876393ca-49e3-4d2d-bc42-7bd9dc354c8d	cd10c6b3-44f9-42dd-9c13-de9922f60581	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
60ae5c50-a5c9-49ee-82a7-3d8e72d8cae0	cd10c6b3-44f9-42dd-9c13-de9922f60581	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
889718fd-8b25-4139-83bc-43d4bf726eef	cd10c6b3-44f9-42dd-9c13-de9922f60581	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4b901c4a-5136-4a02-a9a5-747ea9a40c1c	cd10c6b3-44f9-42dd-9c13-de9922f60581	14	3	0.256	339dee6f-1d8f-482c-8465-a87d2650af5e
e5efb081-1395-43ee-8b93-ee13ea512eef	cd10c6b3-44f9-42dd-9c13-de9922f60581	14	4	0.256	339dee6f-1d8f-482c-8465-a87d2650af5e
4f39bd25-deef-4dbd-a99e-dafc2873b358	cd10c6b3-44f9-42dd-9c13-de9922f60581	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
94488246-6ec2-41c9-89ec-405ed6f00e06	cd10c6b3-44f9-42dd-9c13-de9922f60581	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5ac64764-b367-4faf-9280-c2d894aadf06	cd10c6b3-44f9-42dd-9c13-de9922f60581	15	2	0.682	339dee6f-1d8f-482c-8465-a87d2650af5e
0b91e9b5-b398-4ae2-949f-91ad9134a3db	cd10c6b3-44f9-42dd-9c13-de9922f60581	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6cc83988-1a60-47ff-a4f0-9a268cbd5507	cd10c6b3-44f9-42dd-9c13-de9922f60581	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
846df5f4-abec-440e-bcdd-3f9d7d6e979a	cd10c6b3-44f9-42dd-9c13-de9922f60581	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
53bd81cb-ae05-4295-9ed1-41fe5eac8ad7	cd10c6b3-44f9-42dd-9c13-de9922f60581	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ba5d8124-d1ff-418c-bf7c-226b526091c9	cd10c6b3-44f9-42dd-9c13-de9922f60581	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
86831a7b-858a-48be-972f-cc8c07b66553	cd10c6b3-44f9-42dd-9c13-de9922f60581	16	3	0.409	339dee6f-1d8f-482c-8465-a87d2650af5e
d70d9898-b0f4-42be-82d2-1718c703f017	cd10c6b3-44f9-42dd-9c13-de9922f60581	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c249d7f8-5576-4099-9c74-cad4643e54ea	cd10c6b3-44f9-42dd-9c13-de9922f60581	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d093661f-cc3d-4afc-bd27-d99a3b55d345	cd10c6b3-44f9-42dd-9c13-de9922f60581	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c945441d-0d6d-4029-b35b-d8e24d0f1125	cd10c6b3-44f9-42dd-9c13-de9922f60581	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
62784842-b64b-47ca-8bba-a57cb8ca19d8	cd10c6b3-44f9-42dd-9c13-de9922f60581	17	3	0.512	339dee6f-1d8f-482c-8465-a87d2650af5e
2150dcae-39e5-4c27-9645-24e2369a59c2	cd10c6b3-44f9-42dd-9c13-de9922f60581	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9624db84-d56c-4dd3-b5fe-64719a56adf4	cd10c6b3-44f9-42dd-9c13-de9922f60581	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0e41a919-be07-4e3f-a782-70c4923f28dc	cd10c6b3-44f9-42dd-9c13-de9922f60581	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2e7d58be-d8f6-4f18-b71e-215bc0e724c6	cd10c6b3-44f9-42dd-9c13-de9922f60581	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ab68869a-ac13-4e14-a1e2-932f1a0e2aa7	cd10c6b3-44f9-42dd-9c13-de9922f60581	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
499cec81-8712-4316-9088-ebe84f3a8414	cd10c6b3-44f9-42dd-9c13-de9922f60581	18	4	0.512	339dee6f-1d8f-482c-8465-a87d2650af5e
b79f92e0-e0da-4797-b8f2-185f856bfa4a	cd10c6b3-44f9-42dd-9c13-de9922f60581	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
41cefda4-4a98-43a0-9afa-949a5fd3a7e2	abc6a1b9-a813-4f37-8977-a310065f4d59	1	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
fd57f3a8-9f50-44a5-a96f-321912932880	abc6a1b9-a813-4f37-8977-a310065f4d59	1	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b6a697b7-ecae-41db-a394-89c088f0a9b9	abc6a1b9-a813-4f37-8977-a310065f4d59	1	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d0bcdbb7-d1b9-4560-90f3-0556ed870f5f	abc6a1b9-a813-4f37-8977-a310065f4d59	1	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
07a207f1-1011-4674-802f-685f85caa5c2	abc6a1b9-a813-4f37-8977-a310065f4d59	1	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
5aa22ec8-5a7f-4b59-b6ff-5560b61e5bbe	abc6a1b9-a813-4f37-8977-a310065f4d59	2	1	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
a7d2ccab-331c-42db-bd8e-34d12039edf4	abc6a1b9-a813-4f37-8977-a310065f4d59	2	2	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
efe74e78-6f40-4941-99b3-43ed8cdb247b	abc6a1b9-a813-4f37-8977-a310065f4d59	2	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8798bc39-3ced-463d-b949-65d190dae9e6	abc6a1b9-a813-4f37-8977-a310065f4d59	2	4	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
f163e80e-f569-4847-91e9-f1773e377f70	abc6a1b9-a813-4f37-8977-a310065f4d59	2	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
a5e01721-029a-4da3-9f56-799b1bd50f56	abc6a1b9-a813-4f37-8977-a310065f4d59	3	1	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
b2a6bc34-1d09-40d8-98ab-4d00938c5964	abc6a1b9-a813-4f37-8977-a310065f4d59	3	2	0.598	339dee6f-1d8f-482c-8465-a87d2650af5e
0a4dbf00-5c1e-4dc9-b159-79f3a71ce26c	abc6a1b9-a813-4f37-8977-a310065f4d59	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
78b1de37-c0ca-459a-a0d7-d79e0babb9ad	abc6a1b9-a813-4f37-8977-a310065f4d59	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ffe07344-2229-4ad3-9482-9170ca7a1f88	abc6a1b9-a813-4f37-8977-a310065f4d59	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
09c58c34-b65d-4e4b-aff5-409fc84ced7b	abc6a1b9-a813-4f37-8977-a310065f4d59	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b706e121-aa89-45ef-a326-37ae8c9804d8	abc6a1b9-a813-4f37-8977-a310065f4d59	4	2	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
a5dd36a4-26e5-4db5-9cb9-01a4a28300f9	abc6a1b9-a813-4f37-8977-a310065f4d59	4	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b3d465ef-4921-4fea-a5bc-44bbcb27680b	abc6a1b9-a813-4f37-8977-a310065f4d59	4	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b0a60ccc-9dc6-4fe7-9648-958e2b0004ac	abc6a1b9-a813-4f37-8977-a310065f4d59	4	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
e0f0bd7b-cde5-4985-b79d-4b48e5e29866	abc6a1b9-a813-4f37-8977-a310065f4d59	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2c11eedd-e5c1-4aef-860d-0c5c1862fc3e	abc6a1b9-a813-4f37-8977-a310065f4d59	5	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
265724e2-bded-4d93-b700-adde517a4625	abc6a1b9-a813-4f37-8977-a310065f4d59	5	3	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
24c44f24-1897-4032-a287-5fee98905439	abc6a1b9-a813-4f37-8977-a310065f4d59	5	4	2.000	339dee6f-1d8f-482c-8465-a87d2650af5e
79ad953c-9bfe-4a93-9cf8-b7cd00e57b9e	abc6a1b9-a813-4f37-8977-a310065f4d59	5	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
a311308f-8069-4e77-916d-bff6d0378287	abc6a1b9-a813-4f37-8977-a310065f4d59	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
77a8a822-9da6-4c6f-b604-01b05afe014c	abc6a1b9-a813-4f37-8977-a310065f4d59	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
989f1aa5-b6af-4ef9-a208-54b299d3002c	abc6a1b9-a813-4f37-8977-a310065f4d59	6	3	3.238	339dee6f-1d8f-482c-8465-a87d2650af5e
2cd01976-30a3-4c6f-bfc8-7098f2b1f138	abc6a1b9-a813-4f37-8977-a310065f4d59	6	4	5.978	339dee6f-1d8f-482c-8465-a87d2650af5e
87571239-9fbb-45d9-931a-05ab5174adc6	abc6a1b9-a813-4f37-8977-a310065f4d59	6	5	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
f4ce9afc-3476-46dd-8928-6409e511c505	abc6a1b9-a813-4f37-8977-a310065f4d59	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c8e9c644-bec4-4f10-a30f-e012c8d020d0	abc6a1b9-a813-4f37-8977-a310065f4d59	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
23aab70a-e5fa-48c8-9e6a-8eff7e874771	abc6a1b9-a813-4f37-8977-a310065f4d59	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
06405aa1-d7ad-40dd-86c2-fa1e02ce50bd	abc6a1b9-a813-4f37-8977-a310065f4d59	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d8d54013-3c99-4136-8a41-bff662924ee6	abc6a1b9-a813-4f37-8977-a310065f4d59	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ccbf4205-9cb7-48a3-a7b7-312b3f6dd2cc	abc6a1b9-a813-4f37-8977-a310065f4d59	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
24479f71-0a17-4dfa-adea-6cdf35a375e1	abc6a1b9-a813-4f37-8977-a310065f4d59	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f6bbb200-0d50-4b06-8cca-0cabcecb8cef	abc6a1b9-a813-4f37-8977-a310065f4d59	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82eb1bb7-3ce3-4d3e-a536-12b19c608702	abc6a1b9-a813-4f37-8977-a310065f4d59	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e447ae08-c12a-46e0-b1c8-23cef4b97d11	abc6a1b9-a813-4f37-8977-a310065f4d59	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82820a01-ee7d-439e-bdcf-09bb475cc708	abc6a1b9-a813-4f37-8977-a310065f4d59	9	1	1.495	339dee6f-1d8f-482c-8465-a87d2650af5e
54e1a5c8-f77e-4a62-9a38-f21767eb3439	abc6a1b9-a813-4f37-8977-a310065f4d59	9	2	2.491	339dee6f-1d8f-482c-8465-a87d2650af5e
12b78c2a-33f5-4616-baba-9cf5b8056326	abc6a1b9-a813-4f37-8977-a310065f4d59	9	3	4.982	339dee6f-1d8f-482c-8465-a87d2650af5e
b8f6a29d-87d3-4c75-95a2-066d4727de98	abc6a1b9-a813-4f37-8977-a310065f4d59	9	4	1.993	339dee6f-1d8f-482c-8465-a87d2650af5e
39e0bc88-2419-4b1d-9f5c-8d03602bf507	abc6a1b9-a813-4f37-8977-a310065f4d59	9	5	0.996	339dee6f-1d8f-482c-8465-a87d2650af5e
636f1304-93bf-4a83-9569-8eb2694c0b60	abc6a1b9-a813-4f37-8977-a310065f4d59	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5596d009-6443-4b94-b502-3135a7098c35	abc6a1b9-a813-4f37-8977-a310065f4d59	10	2	0.996	339dee6f-1d8f-482c-8465-a87d2650af5e
319ded92-2a4f-4e79-be10-8ff99648fa1d	abc6a1b9-a813-4f37-8977-a310065f4d59	10	3	1.993	339dee6f-1d8f-482c-8465-a87d2650af5e
4f6ab5b6-cb02-4f8e-b367-6547c6a4eaec	abc6a1b9-a813-4f37-8977-a310065f4d59	10	4	1.993	339dee6f-1d8f-482c-8465-a87d2650af5e
e041ad51-7021-4fe1-9c38-6a833df94be2	abc6a1b9-a813-4f37-8977-a310065f4d59	10	5	0.498	339dee6f-1d8f-482c-8465-a87d2650af5e
aec4f5bf-cb27-4eb5-b627-176d9feff374	abc6a1b9-a813-4f37-8977-a310065f4d59	11	1	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
2c5e5d66-da8e-4398-a041-e24deade44c1	abc6a1b9-a813-4f37-8977-a310065f4d59	11	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
17f89695-fb35-467a-9def-dc3100cd1c11	abc6a1b9-a813-4f37-8977-a310065f4d59	11	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aa1db531-bf6b-4885-a438-aaabda2911f4	abc6a1b9-a813-4f37-8977-a310065f4d59	11	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
268e3774-704e-46bf-be29-18bbf96e3ffe	abc6a1b9-a813-4f37-8977-a310065f4d59	11	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
b25af4f3-6ed5-467c-98d0-edaf66b8666f	abc6a1b9-a813-4f37-8977-a310065f4d59	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4d413faf-7daa-44ec-b5ec-484d9f4348d6	abc6a1b9-a813-4f37-8977-a310065f4d59	12	2	0.996	339dee6f-1d8f-482c-8465-a87d2650af5e
c0bd85ee-2423-4e77-ab41-bb60f4109a7e	abc6a1b9-a813-4f37-8977-a310065f4d59	12	3	3.985	339dee6f-1d8f-482c-8465-a87d2650af5e
4f8f3c4d-9b34-4386-9f17-4326b58f8398	abc6a1b9-a813-4f37-8977-a310065f4d59	12	4	3.985	339dee6f-1d8f-482c-8465-a87d2650af5e
a14838a2-cea7-4d99-87b0-2a2b6374a554	abc6a1b9-a813-4f37-8977-a310065f4d59	12	5	0.623	339dee6f-1d8f-482c-8465-a87d2650af5e
2c5d095d-330b-495f-9730-183b8c303f89	abc6a1b9-a813-4f37-8977-a310065f4d59	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
024a0d1c-4f9b-4f8f-b768-3d1e5f67b76f	abc6a1b9-a813-4f37-8977-a310065f4d59	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cdc58f0c-bbe4-486b-99f5-dbe2c8cfbed9	abc6a1b9-a813-4f37-8977-a310065f4d59	13	3	2.989	339dee6f-1d8f-482c-8465-a87d2650af5e
a5bc2f2e-2fab-4aa7-a76b-3cb4ed0953de	abc6a1b9-a813-4f37-8977-a310065f4d59	13	4	3.587	339dee6f-1d8f-482c-8465-a87d2650af5e
76c4ae71-7b53-4e5a-90b6-9ea8152ea34b	abc6a1b9-a813-4f37-8977-a310065f4d59	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9f5d3d53-a3fa-47e5-b68e-eb62393e7762	abc6a1b9-a813-4f37-8977-a310065f4d59	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
465df1a7-6105-4dd7-b493-18e79fcbbfa2	abc6a1b9-a813-4f37-8977-a310065f4d59	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
71478fdc-765a-467e-b65f-e873550b6a25	abc6a1b9-a813-4f37-8977-a310065f4d59	14	3	0.374	339dee6f-1d8f-482c-8465-a87d2650af5e
0a89a2cd-bcf0-4033-86aa-82f6df206d92	abc6a1b9-a813-4f37-8977-a310065f4d59	14	4	0.374	339dee6f-1d8f-482c-8465-a87d2650af5e
14802f74-0d05-4e3f-adf9-e168b033bdad	abc6a1b9-a813-4f37-8977-a310065f4d59	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1a2c9705-a4e6-45ce-a803-0e4125153e96	abc6a1b9-a813-4f37-8977-a310065f4d59	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b2445186-b14b-4e23-a370-bba6a60d2367	abc6a1b9-a813-4f37-8977-a310065f4d59	15	2	0.996	339dee6f-1d8f-482c-8465-a87d2650af5e
26bda441-392f-4901-9ddd-b63efaeb420b	abc6a1b9-a813-4f37-8977-a310065f4d59	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
db1f978b-2db3-4ff3-b6b0-a8003de51f00	abc6a1b9-a813-4f37-8977-a310065f4d59	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
21f803c5-ec09-42f1-bc7f-fa2d47f82f76	abc6a1b9-a813-4f37-8977-a310065f4d59	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82f9be79-637d-4705-a2eb-72cd6a6b16a5	abc6a1b9-a813-4f37-8977-a310065f4d59	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
71d3944f-359b-4e3e-bf48-2ebaafc7bb25	abc6a1b9-a813-4f37-8977-a310065f4d59	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e3234e54-b0e0-4734-93d6-ff79a7f92578	abc6a1b9-a813-4f37-8977-a310065f4d59	16	3	0.598	339dee6f-1d8f-482c-8465-a87d2650af5e
30cd40c3-727e-4164-9e89-b79da3c0737b	abc6a1b9-a813-4f37-8977-a310065f4d59	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a28b6cdc-9682-434d-ab1b-e4478aea0bb8	abc6a1b9-a813-4f37-8977-a310065f4d59	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5b550ef5-e604-4f5b-9e1c-18e10b2cbc3d	abc6a1b9-a813-4f37-8977-a310065f4d59	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7b023322-eac0-4bc2-bfb8-ac8d4de7614f	abc6a1b9-a813-4f37-8977-a310065f4d59	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
584bf8c8-2baf-4d6e-9658-cfc0f75e37e5	abc6a1b9-a813-4f37-8977-a310065f4d59	17	3	0.747	339dee6f-1d8f-482c-8465-a87d2650af5e
364bf5ec-8e1d-41f2-9df2-da08dff2ef7b	abc6a1b9-a813-4f37-8977-a310065f4d59	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f56065cd-b54e-4379-b148-f66207a57148	abc6a1b9-a813-4f37-8977-a310065f4d59	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ac77a7b4-121f-40e3-b4d0-d0ccd3b316ad	abc6a1b9-a813-4f37-8977-a310065f4d59	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ebb0a399-6f37-4791-8b0e-277a020009ac	abc6a1b9-a813-4f37-8977-a310065f4d59	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3c512378-fcf7-4d18-a821-71766f97cfe1	abc6a1b9-a813-4f37-8977-a310065f4d59	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6f516f04-b129-4e3d-9e1b-3cfd006aed1b	abc6a1b9-a813-4f37-8977-a310065f4d59	18	4	0.747	339dee6f-1d8f-482c-8465-a87d2650af5e
4030dd7f-8210-4fe2-8ab3-ca6cdb43bc66	abc6a1b9-a813-4f37-8977-a310065f4d59	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c377a296-934a-4cf4-98cf-46d31a0992ea	8335a07b-0017-42a8-85dc-098013d4155d	1	1	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
aa892f38-a8ba-4dea-98a9-e5d49004021a	8335a07b-0017-42a8-85dc-098013d4155d	1	2	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
28cfb099-36f3-4d70-a6cd-4116adaad1ea	8335a07b-0017-42a8-85dc-098013d4155d	1	3	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
7f3bc068-b845-4776-b33a-8d88421d13a2	8335a07b-0017-42a8-85dc-098013d4155d	1	4	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
7d2c86ac-67cd-4631-8ec1-29c1a41b813b	8335a07b-0017-42a8-85dc-098013d4155d	1	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
f9343532-95c3-4b01-bc73-5f88a5e39c75	8335a07b-0017-42a8-85dc-098013d4155d	2	1	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
37269d62-d100-4517-b5dd-2d3683203539	8335a07b-0017-42a8-85dc-098013d4155d	2	2	0.129	339dee6f-1d8f-482c-8465-a87d2650af5e
5fc01b2d-d049-460c-95cd-42e79e3e7381	8335a07b-0017-42a8-85dc-098013d4155d	2	3	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
6c19c111-6ad6-4db4-a972-0c0a46fe2a1c	8335a07b-0017-42a8-85dc-098013d4155d	2	4	0.129	339dee6f-1d8f-482c-8465-a87d2650af5e
2a1d9a45-2350-410b-a5e4-639128b87b51	8335a07b-0017-42a8-85dc-098013d4155d	2	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
2bf237b6-cd78-43a9-b096-1557d49a73c1	8335a07b-0017-42a8-85dc-098013d4155d	3	1	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
43f38182-aa25-4485-8bd4-c827b497e95a	8335a07b-0017-42a8-85dc-098013d4155d	3	2	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
de31cbc0-ccaa-4454-a362-58acb16c975b	8335a07b-0017-42a8-85dc-098013d4155d	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1ce7b814-d346-4274-8613-916df067d48e	8335a07b-0017-42a8-85dc-098013d4155d	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9e583bb1-17ed-4d7d-b66c-ce38188f09dc	8335a07b-0017-42a8-85dc-098013d4155d	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a2082c83-39e4-4f8b-98c2-7e94d82d6ea5	8335a07b-0017-42a8-85dc-098013d4155d	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
94bf5c12-a6fc-419d-a6b5-ca63fb701dd9	8335a07b-0017-42a8-85dc-098013d4155d	4	2	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
d97cf73d-2b82-4901-b81f-8bb5b030db4b	8335a07b-0017-42a8-85dc-098013d4155d	4	3	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
06d65ff0-6899-4e9a-affa-76309c95ec14	8335a07b-0017-42a8-85dc-098013d4155d	4	4	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
28ab5080-2e62-435f-ac88-380dfd4a91d6	8335a07b-0017-42a8-85dc-098013d4155d	4	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
70f203db-bf95-4588-ae92-9f5586e4fbc8	8335a07b-0017-42a8-85dc-098013d4155d	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a05460ee-3983-411b-b23d-ad38c304e517	8335a07b-0017-42a8-85dc-098013d4155d	5	2	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
451a45c6-757f-49ae-9d4c-86b309a08266	8335a07b-0017-42a8-85dc-098013d4155d	5	3	0.344	339dee6f-1d8f-482c-8465-a87d2650af5e
f299ea35-6952-4c79-bcc2-5eb05762131b	8335a07b-0017-42a8-85dc-098013d4155d	5	4	0.344	339dee6f-1d8f-482c-8465-a87d2650af5e
d3208102-3c8d-4886-ac30-e80d82b953e4	8335a07b-0017-42a8-85dc-098013d4155d	5	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
13c48c56-023c-4ff8-9e97-b5ff47b8751d	8335a07b-0017-42a8-85dc-098013d4155d	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7fde972e-91d0-4023-99b2-b223c0e2705c	8335a07b-0017-42a8-85dc-098013d4155d	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b224dc41-5839-407a-a90b-d1c90a1cd2aa	8335a07b-0017-42a8-85dc-098013d4155d	6	3	0.219	339dee6f-1d8f-482c-8465-a87d2650af5e
1b0e6496-f3ff-456d-ae8a-d04647136233	8335a07b-0017-42a8-85dc-098013d4155d	6	4	0.405	339dee6f-1d8f-482c-8465-a87d2650af5e
66a1babc-7924-4a09-983c-dbf99773244d	8335a07b-0017-42a8-85dc-098013d4155d	6	5	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
73c12e21-7dcd-46cd-829d-8be7047e3e08	8335a07b-0017-42a8-85dc-098013d4155d	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
081921e0-9229-4709-a197-429ffddfbdf9	8335a07b-0017-42a8-85dc-098013d4155d	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4001398f-9213-4800-b33d-96e6adc935f4	8335a07b-0017-42a8-85dc-098013d4155d	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b3bd261c-dc61-40c4-bfdc-3e468c37432f	8335a07b-0017-42a8-85dc-098013d4155d	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
76569e27-1700-41de-8684-9257c9511634	8335a07b-0017-42a8-85dc-098013d4155d	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e4a4d1f0-a5ed-4953-a1de-33d00a74e46a	8335a07b-0017-42a8-85dc-098013d4155d	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4d876f77-a7d4-431f-8575-13f0d6e75e55	8335a07b-0017-42a8-85dc-098013d4155d	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
478294db-b52f-429d-96da-bb34e1220297	8335a07b-0017-42a8-85dc-098013d4155d	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9198d22b-7112-47d7-808e-1d5f7ba27505	8335a07b-0017-42a8-85dc-098013d4155d	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
417b1549-b821-43eb-9eee-e3b3d84c971f	8335a07b-0017-42a8-85dc-098013d4155d	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0e282d9e-593d-4929-9194-5da15de6cc7a	8335a07b-0017-42a8-85dc-098013d4155d	9	1	0.101	339dee6f-1d8f-482c-8465-a87d2650af5e
e5322df7-7f6f-4c2f-9671-f1209795e1d4	8335a07b-0017-42a8-85dc-098013d4155d	9	2	0.169	339dee6f-1d8f-482c-8465-a87d2650af5e
18384574-be2c-48f8-b3a2-8cb32707d612	8335a07b-0017-42a8-85dc-098013d4155d	9	3	0.337	339dee6f-1d8f-482c-8465-a87d2650af5e
ed477e0f-4271-48f3-aff3-0e51756344a8	8335a07b-0017-42a8-85dc-098013d4155d	9	4	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
21ce81ce-92c3-4856-8d44-cf713839ab5b	8335a07b-0017-42a8-85dc-098013d4155d	9	5	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
8f829094-9546-4e4c-b7da-cfc557d49981	8335a07b-0017-42a8-85dc-098013d4155d	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9028c50f-b099-4f46-b9da-930b144a7df3	8335a07b-0017-42a8-85dc-098013d4155d	10	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
5cb410b2-610d-4031-9bab-d50e1f49c00a	8335a07b-0017-42a8-85dc-098013d4155d	10	3	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
85ecebf1-f083-4976-a25c-ff5cdba90b91	8335a07b-0017-42a8-85dc-098013d4155d	10	4	0.135	339dee6f-1d8f-482c-8465-a87d2650af5e
5ab8b342-d49e-4c84-92ef-8caa974ea125	8335a07b-0017-42a8-85dc-098013d4155d	10	5	0.034	339dee6f-1d8f-482c-8465-a87d2650af5e
9dad9650-a868-4916-864c-b37fd4659c9e	8335a07b-0017-42a8-85dc-098013d4155d	11	1	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
930fdef2-2581-4768-b351-8c038ce4745d	8335a07b-0017-42a8-85dc-098013d4155d	11	2	0.069	339dee6f-1d8f-482c-8465-a87d2650af5e
038c9b83-ce6a-45a2-a962-80e9bd5a0acb	8335a07b-0017-42a8-85dc-098013d4155d	11	3	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
f5435d18-4b9d-46c6-8c6c-a24d431022ec	8335a07b-0017-42a8-85dc-098013d4155d	11	4	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
9c3e16d2-38cf-46f7-86df-e903a05f9410	8335a07b-0017-42a8-85dc-098013d4155d	11	5	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
7825f5f4-998a-4861-a826-eee1a4759c6e	8335a07b-0017-42a8-85dc-098013d4155d	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4d92d535-178c-4552-970c-75335a59ec07	8335a07b-0017-42a8-85dc-098013d4155d	12	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
d1b32507-f24e-4e9d-ac76-5d61182f6155	8335a07b-0017-42a8-85dc-098013d4155d	12	3	0.270	339dee6f-1d8f-482c-8465-a87d2650af5e
97360ccc-a4a0-420d-8f3c-464ec78ecf2e	8335a07b-0017-42a8-85dc-098013d4155d	12	4	0.270	339dee6f-1d8f-482c-8465-a87d2650af5e
1137113d-5be0-4057-a729-8b66ecfad5ae	8335a07b-0017-42a8-85dc-098013d4155d	12	5	0.042	339dee6f-1d8f-482c-8465-a87d2650af5e
68387f6b-a49a-4b64-a3bb-03392161c5b2	8335a07b-0017-42a8-85dc-098013d4155d	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c0c0fd92-ba6e-4a80-b2b0-2cb7c26d0d13	8335a07b-0017-42a8-85dc-098013d4155d	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
08a7762f-cb01-42ca-af0d-840d63606718	8335a07b-0017-42a8-85dc-098013d4155d	13	3	0.202	339dee6f-1d8f-482c-8465-a87d2650af5e
140e8e0f-f80d-4f10-9d97-ff48bd8bdeb9	8335a07b-0017-42a8-85dc-098013d4155d	13	4	0.243	339dee6f-1d8f-482c-8465-a87d2650af5e
47d01804-d7ae-4a97-bff4-114afe120fa8	8335a07b-0017-42a8-85dc-098013d4155d	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
445e31e4-7d93-498d-89e1-40d861a4f9a1	8335a07b-0017-42a8-85dc-098013d4155d	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
83e686a2-c164-4a5f-b0f0-1811c0c6d877	8335a07b-0017-42a8-85dc-098013d4155d	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74c2fb41-4e05-474f-9064-4a82970b1e49	8335a07b-0017-42a8-85dc-098013d4155d	14	3	0.025	339dee6f-1d8f-482c-8465-a87d2650af5e
27066097-960c-446c-8e90-30922688ef8d	8335a07b-0017-42a8-85dc-098013d4155d	14	4	0.025	339dee6f-1d8f-482c-8465-a87d2650af5e
17b04d1b-94f9-4e46-b12d-d315f0de7a2d	8335a07b-0017-42a8-85dc-098013d4155d	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2fdf0a46-27c4-4948-94a9-bf364d252986	8335a07b-0017-42a8-85dc-098013d4155d	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
75d12779-aad1-4995-b3bd-58794f079609	8335a07b-0017-42a8-85dc-098013d4155d	15	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
ef74781b-8711-4828-ae43-3aae74beefd8	8335a07b-0017-42a8-85dc-098013d4155d	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
561aba59-40f1-4f94-a349-e3a0d53ca929	8335a07b-0017-42a8-85dc-098013d4155d	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
32cba816-ccce-4dd6-bfbe-6db94386aeb0	8335a07b-0017-42a8-85dc-098013d4155d	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
96cc511a-2f33-4220-a406-f05a2bac8679	8335a07b-0017-42a8-85dc-098013d4155d	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cd455fe5-82b0-48d1-bcc6-937a4db913ec	8335a07b-0017-42a8-85dc-098013d4155d	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c69c87ab-f79c-4ad7-97be-f4ea81d452fa	8335a07b-0017-42a8-85dc-098013d4155d	16	3	0.040	339dee6f-1d8f-482c-8465-a87d2650af5e
bc14b2ea-fea7-4245-b7eb-e9b6eebd7d42	8335a07b-0017-42a8-85dc-098013d4155d	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d6068489-38e9-444b-8d26-37c6b04beda4	8335a07b-0017-42a8-85dc-098013d4155d	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0620155-9aaa-40e0-af8d-ce0c5c52ffd8	8335a07b-0017-42a8-85dc-098013d4155d	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c81f295c-1c1c-4f7e-ae94-21b9eb249db8	8335a07b-0017-42a8-85dc-098013d4155d	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4c20bc6c-4670-4316-9df9-5aaad75ab290	8335a07b-0017-42a8-85dc-098013d4155d	17	3	0.051	339dee6f-1d8f-482c-8465-a87d2650af5e
b522acbe-70cb-40a4-9dfb-30da634b93a9	8335a07b-0017-42a8-85dc-098013d4155d	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2533c19a-3477-47d8-af17-c53d820492a0	8335a07b-0017-42a8-85dc-098013d4155d	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ac68c605-e9fe-4b87-a547-c9229f171acc	8335a07b-0017-42a8-85dc-098013d4155d	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a61bfa26-9814-4fac-8073-9e0e4725a9a0	8335a07b-0017-42a8-85dc-098013d4155d	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
26faa943-f32c-4a1a-9d2e-20e972e1f614	8335a07b-0017-42a8-85dc-098013d4155d	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8f31dc27-1f8b-483b-bcdc-c3ac5d314408	8335a07b-0017-42a8-85dc-098013d4155d	18	4	0.051	339dee6f-1d8f-482c-8465-a87d2650af5e
ba3902a2-3cd7-49d4-a27d-21baad350e06	8335a07b-0017-42a8-85dc-098013d4155d	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
144053e2-e942-493b-8e88-618df28b80f5	27069b0b-5405-42ba-885c-4887a2a3ef71	1	1	0.453	339dee6f-1d8f-482c-8465-a87d2650af5e
46930437-a1ee-419c-9db1-521dc9586e66	27069b0b-5405-42ba-885c-4887a2a3ef71	1	2	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
539fcaef-ee1f-44d3-99f8-f8478c8fc345	27069b0b-5405-42ba-885c-4887a2a3ef71	1	3	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
4f2ed137-c009-418d-8111-104e7545c773	27069b0b-5405-42ba-885c-4887a2a3ef71	1	4	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
b8e6c740-d66f-4acc-9078-51603f85fce4	27069b0b-5405-42ba-885c-4887a2a3ef71	1	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
c27612fd-daa8-4a30-af94-0b03b3f4adf2	27069b0b-5405-42ba-885c-4887a2a3ef71	2	1	0.453	339dee6f-1d8f-482c-8465-a87d2650af5e
6fcaa690-ff08-41ad-bd7a-7f65e9b100d5	27069b0b-5405-42ba-885c-4887a2a3ef71	2	2	0.679	339dee6f-1d8f-482c-8465-a87d2650af5e
2a6e43b2-c694-40b0-9536-d18bc4f2c64d	27069b0b-5405-42ba-885c-4887a2a3ef71	2	3	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
e2e6b335-d40d-4098-becf-f3e438b4b64b	27069b0b-5405-42ba-885c-4887a2a3ef71	2	4	0.679	339dee6f-1d8f-482c-8465-a87d2650af5e
c55bde28-d41c-47ec-ada3-8dd2e3918501	27069b0b-5405-42ba-885c-4887a2a3ef71	2	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
0d07993e-b60f-426e-953f-20f10a02e57d	27069b0b-5405-42ba-885c-4887a2a3ef71	3	1	0.209	339dee6f-1d8f-482c-8465-a87d2650af5e
924865d5-76dc-4af7-92da-276fe24ff7ca	27069b0b-5405-42ba-885c-4887a2a3ef71	3	2	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
9c63f44b-5894-4c70-929e-5814a3735781	27069b0b-5405-42ba-885c-4887a2a3ef71	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2b72089a-22e9-46ae-98a2-a9ba0e45594f	27069b0b-5405-42ba-885c-4887a2a3ef71	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0402471-62e8-4744-98b1-af616701af11	27069b0b-5405-42ba-885c-4887a2a3ef71	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
26dbb347-b376-4ee6-89f3-45f1fb1d823b	27069b0b-5405-42ba-885c-4887a2a3ef71	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b3429f92-7c4a-4523-9001-489d870aeca8	27069b0b-5405-42ba-885c-4887a2a3ef71	4	2	0.453	339dee6f-1d8f-482c-8465-a87d2650af5e
61e0e41d-16d5-4de1-8c88-bf43d9d64312	27069b0b-5405-42ba-885c-4887a2a3ef71	4	3	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
dca132db-7d75-4649-b7f1-0000970aa410	27069b0b-5405-42ba-885c-4887a2a3ef71	4	4	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
baa956c3-b3f5-4418-9829-832a9c77c316	27069b0b-5405-42ba-885c-4887a2a3ef71	4	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
5ec19be4-88cc-4ad2-b7d3-2ffe51f29f0f	27069b0b-5405-42ba-885c-4887a2a3ef71	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9759c6e8-c53c-4623-be92-1af9fbb08a99	27069b0b-5405-42ba-885c-4887a2a3ef71	5	2	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
eda81e63-1bc3-4e2d-b244-623ebc95a387	27069b0b-5405-42ba-885c-4887a2a3ef71	5	3	1.811	339dee6f-1d8f-482c-8465-a87d2650af5e
def59e6e-8275-4921-8d46-d151364402ba	27069b0b-5405-42ba-885c-4887a2a3ef71	5	4	1.811	339dee6f-1d8f-482c-8465-a87d2650af5e
764151e9-015f-4556-86af-da75c966e3a6	27069b0b-5405-42ba-885c-4887a2a3ef71	5	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
5318a7a8-4beb-4a95-8f51-b28b9833d4aa	27069b0b-5405-42ba-885c-4887a2a3ef71	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cf27fcb3-eff8-492e-865b-f9110c1a7882	27069b0b-5405-42ba-885c-4887a2a3ef71	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6d265106-b8e8-4cad-8b6e-85c6f8d06775	27069b0b-5405-42ba-885c-4887a2a3ef71	6	3	1.357	339dee6f-1d8f-482c-8465-a87d2650af5e
62830eb3-405a-42ab-a150-6ce96ff56afb	27069b0b-5405-42ba-885c-4887a2a3ef71	6	4	2.505	339dee6f-1d8f-482c-8465-a87d2650af5e
4c59dfa0-6a46-4b84-9bec-0693c78bc345	27069b0b-5405-42ba-885c-4887a2a3ef71	6	5	0.209	339dee6f-1d8f-482c-8465-a87d2650af5e
99eaa853-2f7d-4631-a540-b51e7f7fa161	27069b0b-5405-42ba-885c-4887a2a3ef71	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a89829f3-3e04-4b84-b9a2-de958bcf7ce5	27069b0b-5405-42ba-885c-4887a2a3ef71	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
58a93000-0d3c-427f-b522-d4027f840b9b	27069b0b-5405-42ba-885c-4887a2a3ef71	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
20d4f075-d2fb-4132-a92e-b1a21f4f74ff	27069b0b-5405-42ba-885c-4887a2a3ef71	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
939d561a-7109-4afc-a7e9-a7813b26e0a1	27069b0b-5405-42ba-885c-4887a2a3ef71	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
98bd89e9-cff7-4cec-af53-de5eac015a77	27069b0b-5405-42ba-885c-4887a2a3ef71	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
86a77f9e-f509-40cb-a42f-b60b85a5e8fe	27069b0b-5405-42ba-885c-4887a2a3ef71	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82d128f4-b222-465a-a7a3-e46a8d53bfb0	27069b0b-5405-42ba-885c-4887a2a3ef71	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9ddb8fa2-cf37-4c1a-b47d-c6c37495341c	27069b0b-5405-42ba-885c-4887a2a3ef71	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aab2ddde-34c9-464a-839a-28d15e9acfc5	27069b0b-5405-42ba-885c-4887a2a3ef71	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c9ba6786-6a9e-4842-bc9b-6bf8c16ec078	27069b0b-5405-42ba-885c-4887a2a3ef71	9	1	0.626	339dee6f-1d8f-482c-8465-a87d2650af5e
a25eba72-a0ab-45eb-92fa-cde79c9e975a	27069b0b-5405-42ba-885c-4887a2a3ef71	9	2	1.044	339dee6f-1d8f-482c-8465-a87d2650af5e
e9c58dc0-3a8c-40a9-9915-6ba19956dd81	27069b0b-5405-42ba-885c-4887a2a3ef71	9	3	2.087	339dee6f-1d8f-482c-8465-a87d2650af5e
b9ff7c8d-fe1d-4e84-93c9-7ef698a958a6	27069b0b-5405-42ba-885c-4887a2a3ef71	9	4	0.835	339dee6f-1d8f-482c-8465-a87d2650af5e
6e1b0ae6-8e3e-4d27-86b0-c583fa013cf2	27069b0b-5405-42ba-885c-4887a2a3ef71	9	5	0.417	339dee6f-1d8f-482c-8465-a87d2650af5e
b7222c3b-96cc-4359-8183-306e4c564ef1	27069b0b-5405-42ba-885c-4887a2a3ef71	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8de5218d-ba3d-415f-931f-516bdc6f0522	27069b0b-5405-42ba-885c-4887a2a3ef71	10	2	0.417	339dee6f-1d8f-482c-8465-a87d2650af5e
5acb0d9f-4b14-4737-8a43-9833e5b5760f	27069b0b-5405-42ba-885c-4887a2a3ef71	10	3	0.835	339dee6f-1d8f-482c-8465-a87d2650af5e
dab53cc6-4248-4c10-9921-056b60320a2f	27069b0b-5405-42ba-885c-4887a2a3ef71	10	4	0.835	339dee6f-1d8f-482c-8465-a87d2650af5e
d01cf73e-603a-4b28-a55c-46a5c0e90e68	27069b0b-5405-42ba-885c-4887a2a3ef71	10	5	0.209	339dee6f-1d8f-482c-8465-a87d2650af5e
62787938-25b6-4fe4-9afc-5db2c31090d3	27069b0b-5405-42ba-885c-4887a2a3ef71	11	1	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
dc3f0837-c3bd-4c9a-9f10-37a3abd6bccf	27069b0b-5405-42ba-885c-4887a2a3ef71	11	2	0.362	339dee6f-1d8f-482c-8465-a87d2650af5e
e551ba12-1987-4efc-a4db-f04de3911b5d	27069b0b-5405-42ba-885c-4887a2a3ef71	11	3	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
1f3ec5d4-b60f-4338-b7a3-4c984e722d12	27069b0b-5405-42ba-885c-4887a2a3ef71	11	4	0.905	339dee6f-1d8f-482c-8465-a87d2650af5e
d54b559b-bc70-4000-8b40-c414d7c98715	27069b0b-5405-42ba-885c-4887a2a3ef71	11	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
04746685-5976-444d-b761-b32315c8a9cb	27069b0b-5405-42ba-885c-4887a2a3ef71	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6c630820-8274-4828-a79d-f8d95318e1f8	27069b0b-5405-42ba-885c-4887a2a3ef71	12	2	0.417	339dee6f-1d8f-482c-8465-a87d2650af5e
7eae95c7-d635-49a6-a129-ebe840855386	27069b0b-5405-42ba-885c-4887a2a3ef71	12	3	1.670	339dee6f-1d8f-482c-8465-a87d2650af5e
6ee7262d-6174-4480-b955-980e10a36e04	27069b0b-5405-42ba-885c-4887a2a3ef71	12	4	1.670	339dee6f-1d8f-482c-8465-a87d2650af5e
5c02861e-27d0-4ddf-9885-d780946dca20	27069b0b-5405-42ba-885c-4887a2a3ef71	12	5	0.261	339dee6f-1d8f-482c-8465-a87d2650af5e
10df1017-adee-406f-adca-f7d8792305da	27069b0b-5405-42ba-885c-4887a2a3ef71	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
85ec4eaf-9861-4cb0-a349-fefc36a346e2	27069b0b-5405-42ba-885c-4887a2a3ef71	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
314ab7b5-cf14-418d-81d3-f9fb50491a5c	27069b0b-5405-42ba-885c-4887a2a3ef71	13	3	1.252	339dee6f-1d8f-482c-8465-a87d2650af5e
3e916c36-5777-4895-b997-4313709dbff3	27069b0b-5405-42ba-885c-4887a2a3ef71	13	4	1.503	339dee6f-1d8f-482c-8465-a87d2650af5e
66409a86-4df8-419c-8dd0-d49757edbf74	27069b0b-5405-42ba-885c-4887a2a3ef71	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
93683ab9-f457-440c-8ff3-f759e6003791	27069b0b-5405-42ba-885c-4887a2a3ef71	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6b2f9dc4-37cc-4714-af70-95632d064df9	27069b0b-5405-42ba-885c-4887a2a3ef71	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6de41ea7-83e4-42ac-a74f-f7b6c9123330	27069b0b-5405-42ba-885c-4887a2a3ef71	14	3	0.157	339dee6f-1d8f-482c-8465-a87d2650af5e
d0e5a65e-a471-4b10-8090-771b1bc5ca58	27069b0b-5405-42ba-885c-4887a2a3ef71	14	4	0.157	339dee6f-1d8f-482c-8465-a87d2650af5e
fdfb7415-4f79-4ee8-aac0-b81a92ceb360	27069b0b-5405-42ba-885c-4887a2a3ef71	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b42b8c43-a859-431b-be19-7125822b0113	27069b0b-5405-42ba-885c-4887a2a3ef71	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6f4eaca-83a6-4ce2-98d8-440d64a06894	27069b0b-5405-42ba-885c-4887a2a3ef71	15	2	0.417	339dee6f-1d8f-482c-8465-a87d2650af5e
5cf58d8e-0870-46a9-84af-95830d982758	27069b0b-5405-42ba-885c-4887a2a3ef71	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0ef157e9-fae5-4ca5-88c9-36df75be57a5	27069b0b-5405-42ba-885c-4887a2a3ef71	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a602727a-5816-4beb-85a0-f3c199ecd264	27069b0b-5405-42ba-885c-4887a2a3ef71	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
505183ee-e169-4ec8-b761-562699c6227e	27069b0b-5405-42ba-885c-4887a2a3ef71	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
607982f9-343f-43f2-b73b-c01fd1f9c09a	27069b0b-5405-42ba-885c-4887a2a3ef71	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
68587056-4030-4831-87a1-cc295bb9896d	27069b0b-5405-42ba-885c-4887a2a3ef71	16	3	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
12836c26-32a1-470e-8e83-cac47714d109	27069b0b-5405-42ba-885c-4887a2a3ef71	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e502a348-89ea-47d8-bd83-1a7f44bbba03	27069b0b-5405-42ba-885c-4887a2a3ef71	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f954fe20-fe5e-464a-98c4-e1e7e3066e64	27069b0b-5405-42ba-885c-4887a2a3ef71	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5cae3f91-cabb-4c7e-bf4b-3bb5968b26be	27069b0b-5405-42ba-885c-4887a2a3ef71	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
be987e00-5aaa-4f87-a343-bf5c654a1d2c	27069b0b-5405-42ba-885c-4887a2a3ef71	17	3	0.313	339dee6f-1d8f-482c-8465-a87d2650af5e
f87e7d57-7428-4b17-a49b-21e70409b821	27069b0b-5405-42ba-885c-4887a2a3ef71	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b62df8fb-8e6b-4e83-aa41-0835b071f359	27069b0b-5405-42ba-885c-4887a2a3ef71	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cb92cedd-08fd-4cc1-90bf-87a3eb4431ab	27069b0b-5405-42ba-885c-4887a2a3ef71	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7d05dd30-2238-4cdd-8dc4-37113b795588	27069b0b-5405-42ba-885c-4887a2a3ef71	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b35e9851-bc03-4282-acec-1a22f36ca093	27069b0b-5405-42ba-885c-4887a2a3ef71	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
291a096c-561d-42bc-ad79-9f8188d59945	27069b0b-5405-42ba-885c-4887a2a3ef71	18	4	0.313	339dee6f-1d8f-482c-8465-a87d2650af5e
4f0b3d20-aca3-4412-8608-b391d501b307	27069b0b-5405-42ba-885c-4887a2a3ef71	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b415ebc1-8015-41f3-be9a-c7ae581cc553	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	1	0.443	339dee6f-1d8f-482c-8465-a87d2650af5e
44c87bfa-639e-4ffe-8afe-867b5b566467	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	2	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
b72cf635-053b-42cf-b8af-51890014da47	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
7527c1e8-2ea9-4d5a-a84b-39e67c16194c	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
a246888f-d8af-420a-bfa0-d4492db30d93	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
99d1b7b6-3a66-4ae6-a74b-8844a887785c	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	1	0.443	339dee6f-1d8f-482c-8465-a87d2650af5e
2565c35e-f8a6-4a03-8507-f707fe6560da	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	2	0.665	339dee6f-1d8f-482c-8465-a87d2650af5e
4ff833e1-b503-496f-b89f-c25e16a5dc7c	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
7b135753-a32f-4302-83f1-a1fa3a84a5af	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	4	0.665	339dee6f-1d8f-482c-8465-a87d2650af5e
af4cba6b-18c8-4a08-bc6c-67fc551fd836	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
e6b6a3b1-0b84-4009-a80b-0df4dbae40f9	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	1	0.199	339dee6f-1d8f-482c-8465-a87d2650af5e
f8d073cc-47c8-474f-990a-d4e1688aeb75	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	2	0.238	339dee6f-1d8f-482c-8465-a87d2650af5e
282e00e6-9259-4969-b2b9-416a66326628	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
15a55948-b367-41f9-a2d3-1cc11dfadcb1	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c9911b01-1e0e-4207-9900-92b058617872	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f7dcd146-0184-470c-b9e1-f5fb7b859228	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6d939887-563c-4450-8d3e-0d349da63be9	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	2	0.443	339dee6f-1d8f-482c-8465-a87d2650af5e
5bb654f3-8f5f-4aa9-8684-ae55d3098622	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
aae84af8-446b-4c1b-97af-608ecf386a2f	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
21d49725-ded5-4a72-aac5-e30ae9ae4793	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
b21be0a6-8edf-4222-9024-fdca96561a58	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c40870e7-1b4e-493e-8bea-9b595a0c9d86	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	2	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
4783a230-5d88-49f8-9dc1-e6e718ff949e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	3	1.773	339dee6f-1d8f-482c-8465-a87d2650af5e
3fd8e54c-d76d-4be6-821d-1f2badb40977	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	4	1.773	339dee6f-1d8f-482c-8465-a87d2650af5e
51bb8d08-d743-4db9-a7a8-da9e4c4066bc	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
829aba7d-1ba9-4d98-8051-0382ea43f44c	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
eb213cd9-9399-4abe-a8a1-9be18c8bb194	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1ea4b480-18b6-4aa8-aaa1-1c08cbc28039	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	6	3	1.292	339dee6f-1d8f-482c-8465-a87d2650af5e
af32c860-e9ce-4ce8-837d-90140cb32600	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	6	4	2.385	339dee6f-1d8f-482c-8465-a87d2650af5e
026460ba-7c2c-4c6e-b509-09b0bcedcf72	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	6	5	0.199	339dee6f-1d8f-482c-8465-a87d2650af5e
68caf390-c5ce-49ee-a49b-28b657023823	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f3b55e74-fa5d-42ce-9b80-8748dccf536e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dfcccc57-3180-4cf4-9a5d-68160e1e9896	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4409a92e-16b5-4fbf-8c7a-45603d398564	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3ba82643-558f-49a1-a9ec-7a205b45af02	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f72e3b02-5b4e-46fc-857f-3ea8e7f3de45	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
48e05cff-355c-4897-a286-ad41fa2586de	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdebe1b9-f688-4221-9281-24806001fb47	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
44678d3a-a81a-4357-9249-b56c39bc358f	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af7ed5a5-0392-4d8b-8cc8-fafb4cc7644b	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
43178a0c-8aa2-4875-9bad-8a02eb00c0af	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	9	1	0.596	339dee6f-1d8f-482c-8465-a87d2650af5e
d3ab905e-a1ad-4ea5-8860-958378f002ee	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	9	2	0.994	339dee6f-1d8f-482c-8465-a87d2650af5e
3ae703f4-ddd4-4838-a5a1-bea1316020ed	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	9	3	1.987	339dee6f-1d8f-482c-8465-a87d2650af5e
aeef886c-5e89-4bce-85de-0b5a46712dfe	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	9	4	0.795	339dee6f-1d8f-482c-8465-a87d2650af5e
45cef7bc-6d35-493c-b57f-76f04acc8b06	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	9	5	0.397	339dee6f-1d8f-482c-8465-a87d2650af5e
bd0b2569-d31f-4e3c-b84a-c03dce4385a3	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d0325032-6bcf-4e82-b1e1-296f42b5d1fb	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	10	2	0.397	339dee6f-1d8f-482c-8465-a87d2650af5e
9dec82bc-0963-4777-b9b3-a3e4db95bf09	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	10	3	0.795	339dee6f-1d8f-482c-8465-a87d2650af5e
342a7a6b-6fe8-4714-a8a0-6eed29b96f68	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	10	4	0.795	339dee6f-1d8f-482c-8465-a87d2650af5e
14841fb0-87ad-44c1-9c95-0875b0232456	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	10	5	0.199	339dee6f-1d8f-482c-8465-a87d2650af5e
abf46ae5-0276-47ab-8d6f-328355231999	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	11	1	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
7ad23a57-1711-4df7-99aa-6d58af551749	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	11	2	0.355	339dee6f-1d8f-482c-8465-a87d2650af5e
51c3ff7a-b3c0-4354-b5f8-948ee198b9df	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	11	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
a5e3a130-ae5c-4004-a662-c686928e053a	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	11	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
0a297282-3ebd-4134-9987-cd37c0eb864e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	11	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
d293d45f-be12-4631-8279-7ccabe3c6795	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ac5c36b0-0eb6-4628-b713-17d508bd7e97	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	12	2	0.397	339dee6f-1d8f-482c-8465-a87d2650af5e
749f5705-03fb-40c5-85e1-37718bc8457f	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	12	3	1.590	339dee6f-1d8f-482c-8465-a87d2650af5e
61234e79-d49d-4022-a8c8-13cddd153b84	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	12	4	1.590	339dee6f-1d8f-482c-8465-a87d2650af5e
86353834-6502-4c97-8acf-99403b1125c4	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	12	5	0.248	339dee6f-1d8f-482c-8465-a87d2650af5e
2b87a6bc-4d67-404a-9df4-b34d74c09f6e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b27b4b7d-a3e7-4296-bbba-f1c422c02b1d	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af6b7033-38ed-458c-9ddc-34f80822024e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	13	3	1.192	339dee6f-1d8f-482c-8465-a87d2650af5e
f2b83e7b-c6e7-4064-8ab7-282e16667f75	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	13	4	1.431	339dee6f-1d8f-482c-8465-a87d2650af5e
63bbc662-dea4-49ad-94c9-ae122fe48171	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
24e909e9-a978-41ae-8031-93f7c99c0d16	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b64c0a99-2fe3-4bf7-9c48-f4dab0fbb96a	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fa47a45c-f2c9-47b7-871c-e241c0f4a8ea	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	14	3	0.149	339dee6f-1d8f-482c-8465-a87d2650af5e
6ff9cfda-020a-43c5-8677-1a7d3b6d06ec	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	14	4	0.149	339dee6f-1d8f-482c-8465-a87d2650af5e
de710b18-387b-46cb-8a92-dcc986d35823	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d5416d20-7adf-4248-9e83-bc2daaa462a9	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
285d75ef-c52d-4ed4-9874-46addf47f788	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	15	2	0.397	339dee6f-1d8f-482c-8465-a87d2650af5e
304023f6-bf05-4722-8920-93ac416736b3	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aa3c2359-9652-4b01-9f9c-c7029aa1f6ca	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1ad59664-9af6-49eb-aa63-ebb53b85a807	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5f09cbdb-8e13-4e7d-8535-3900b9161ea8	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
61995adb-9011-4a2a-bb95-1110356dfa44	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2b85e285-b04e-495e-819b-734f6a871c18	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	16	3	0.238	339dee6f-1d8f-482c-8465-a87d2650af5e
7e1fb19a-ac8c-4d38-816a-a17e82b6e354	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
71090ed6-d92d-4f79-b64a-bdca68fec5db	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
86180c8d-bf44-47ca-b77c-517b7b1ae4cd	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6eaa7b10-9a02-4e5f-980f-bd3483004c7c	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
416a3c23-52cb-4b49-8714-c32131e7abcb	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	17	3	0.298	339dee6f-1d8f-482c-8465-a87d2650af5e
55569d3d-1808-4a27-9ff6-bb358834b529	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8025500d-b484-40de-8ef8-747524475691	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c61d1591-5685-421b-bcbc-340e56cf7ff5	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7abdff36-256d-4622-a542-07b27a68c9ca	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
59dde9d1-45f4-4164-ba8d-6c387ca7d80a	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0a32056d-7d2e-4106-9544-3b9be347d0bf	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	18	4	0.298	339dee6f-1d8f-482c-8465-a87d2650af5e
ffdd25c7-d5df-4858-bdeb-fb3a935d38e5	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9ff61790-fc5e-41f4-8fae-f7b9b033fcbe	97642c0e-6ff8-4d75-b036-67ec48b7956c	1	1	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
0a5458e9-44cb-45ce-9097-51425f0470a9	97642c0e-6ff8-4d75-b036-67ec48b7956c	1	2	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
70528515-cbca-44e9-a0a5-509518157559	97642c0e-6ff8-4d75-b036-67ec48b7956c	1	3	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
e7c69dc7-ec58-4ba0-bd15-e435e8fd0312	97642c0e-6ff8-4d75-b036-67ec48b7956c	1	4	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
d1c0f3ea-0400-4f66-b9f7-70082ea5c551	97642c0e-6ff8-4d75-b036-67ec48b7956c	1	5	0.193	339dee6f-1d8f-482c-8465-a87d2650af5e
8a5d8bf1-0053-42be-b762-456336330598	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	1	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
38153ffd-9d4f-4bf1-b1a4-c8ec6798477b	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	2	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
8cec71ee-0c9e-45fc-bbfa-a0430ad0bfc5	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	3	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
0cab8732-5a22-49b2-9dcc-29ba84c72049	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	4	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
0471ae21-e60b-4eb8-82cc-d90c3eb7fe1d	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	5	0.193	339dee6f-1d8f-482c-8465-a87d2650af5e
0fa9c7cc-1ce1-4df9-b839-d9f4e0198a16	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	1	0.154	339dee6f-1d8f-482c-8465-a87d2650af5e
c17dfc8a-7211-4d9c-b902-17e08c627744	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	2	0.185	339dee6f-1d8f-482c-8465-a87d2650af5e
3b494a41-d2d6-4405-a76d-ea09a4f128e8	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
01e83e3a-88ab-4b32-b6c8-79519d61e33d	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
10402870-79c6-4808-a183-5a259823ca1c	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d2dc66f3-9ac0-4553-a184-99aa6e66836b	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4700e789-1edf-4159-8297-3c384cb62e82	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	2	0.386	339dee6f-1d8f-482c-8465-a87d2650af5e
e95c8335-f713-4243-bb70-4a8b3357308c	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	3	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
7e7100a4-45a7-494a-a27d-c3a24acb5ec9	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	4	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
1f616a95-aa7e-4252-89e0-b4889fb83ea8	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	5	0.193	339dee6f-1d8f-482c-8465-a87d2650af5e
ccec7ca1-be9d-4157-86b7-5f8426de3812	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b0d6784e-d79e-4a1c-8b78-53ff0c734e41	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	2	1.159	339dee6f-1d8f-482c-8465-a87d2650af5e
2d106d92-061d-4d8c-83fd-bcd971c1cb5e	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	3	2.317	339dee6f-1d8f-482c-8465-a87d2650af5e
e4545ec1-6ac1-46ad-94b3-3cc307cd7cef	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	4	2.317	339dee6f-1d8f-482c-8465-a87d2650af5e
5eb3ed42-711d-440a-b73a-73a41d8c83a3	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	5	0.290	339dee6f-1d8f-482c-8465-a87d2650af5e
edfbd2f2-d460-4cfb-9059-20196d7efe8b	97642c0e-6ff8-4d75-b036-67ec48b7956c	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fcd74379-7f07-4385-9faf-49942bdbda08	97642c0e-6ff8-4d75-b036-67ec48b7956c	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2f1b5a28-e1c1-4f60-9cd5-2519ed6eeade	97642c0e-6ff8-4d75-b036-67ec48b7956c	6	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
30b51e23-810e-4834-9ce9-444e49419dbe	97642c0e-6ff8-4d75-b036-67ec48b7956c	6	4	2.308	339dee6f-1d8f-482c-8465-a87d2650af5e
8478a15b-6f9d-4135-b5f3-722192d4b7a3	97642c0e-6ff8-4d75-b036-67ec48b7956c	6	5	0.154	339dee6f-1d8f-482c-8465-a87d2650af5e
d8af669d-51d4-4bce-a236-5e3dac101ef3	97642c0e-6ff8-4d75-b036-67ec48b7956c	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6044b252-ef23-4787-9562-04364147b459	97642c0e-6ff8-4d75-b036-67ec48b7956c	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
53393e16-d0f5-4ba4-a76b-fcbb295965c6	97642c0e-6ff8-4d75-b036-67ec48b7956c	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
79318e70-4b27-475d-af08-eb326c768413	97642c0e-6ff8-4d75-b036-67ec48b7956c	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c1bf74c1-0480-48fe-afd0-098e7e4713b2	97642c0e-6ff8-4d75-b036-67ec48b7956c	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
301be634-1754-4866-b223-c12a556becd8	97642c0e-6ff8-4d75-b036-67ec48b7956c	8	1	0.539	339dee6f-1d8f-482c-8465-a87d2650af5e
6a636d08-9e31-4733-a459-a512633c87c5	97642c0e-6ff8-4d75-b036-67ec48b7956c	8	2	1.539	339dee6f-1d8f-482c-8465-a87d2650af5e
9336c915-05ea-4a3b-bfc6-d23188fd989d	97642c0e-6ff8-4d75-b036-67ec48b7956c	8	3	1.539	339dee6f-1d8f-482c-8465-a87d2650af5e
4309952f-78a1-440a-81b7-36b5414a2003	97642c0e-6ff8-4d75-b036-67ec48b7956c	8	4	0.769	339dee6f-1d8f-482c-8465-a87d2650af5e
a9e6df2e-edfa-4c24-ab7b-ce63e9d2498a	97642c0e-6ff8-4d75-b036-67ec48b7956c	8	5	0.308	339dee6f-1d8f-482c-8465-a87d2650af5e
0bb0bc30-db24-4f05-b255-9bfd89485388	97642c0e-6ff8-4d75-b036-67ec48b7956c	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fd0c8fa0-5c92-4309-81d1-26c2b844436b	97642c0e-6ff8-4d75-b036-67ec48b7956c	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
537503d0-5158-4f8a-bac7-1f19d17f789c	97642c0e-6ff8-4d75-b036-67ec48b7956c	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
43a226e5-f0c2-4e83-a231-00453ad21c1a	97642c0e-6ff8-4d75-b036-67ec48b7956c	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ca01ef7e-3234-4e53-87a8-6ddd9541bfe4	97642c0e-6ff8-4d75-b036-67ec48b7956c	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b7164a1-76d8-4dde-90d9-ac762f7e7ebc	97642c0e-6ff8-4d75-b036-67ec48b7956c	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74747367-8047-4d18-b95e-22145f29f121	97642c0e-6ff8-4d75-b036-67ec48b7956c	10	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1ac5f61c-ff99-4e0c-8673-e6de5f2ad32f	97642c0e-6ff8-4d75-b036-67ec48b7956c	10	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
695555f0-043b-4f30-bce7-2cbce1608d99	97642c0e-6ff8-4d75-b036-67ec48b7956c	10	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4096eda0-84dc-475f-9207-020b5b9c181b	97642c0e-6ff8-4d75-b036-67ec48b7956c	10	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
25aa3f20-0c18-4673-91c5-dc90dbd1300a	97642c0e-6ff8-4d75-b036-67ec48b7956c	11	1	0.193	339dee6f-1d8f-482c-8465-a87d2650af5e
f8e22caf-1463-4acd-a82d-aac364c8e88a	97642c0e-6ff8-4d75-b036-67ec48b7956c	11	2	0.309	339dee6f-1d8f-482c-8465-a87d2650af5e
f9420a20-1852-49ee-8c8a-1e8e9c7854c5	97642c0e-6ff8-4d75-b036-67ec48b7956c	11	3	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
9182a561-1716-42d1-a5e6-684318749b0b	97642c0e-6ff8-4d75-b036-67ec48b7956c	11	4	0.772	339dee6f-1d8f-482c-8465-a87d2650af5e
adccda8a-c9aa-4028-bb46-63167cae814b	97642c0e-6ff8-4d75-b036-67ec48b7956c	11	5	0.193	339dee6f-1d8f-482c-8465-a87d2650af5e
420d460d-86e2-4014-85cd-817a3258c031	97642c0e-6ff8-4d75-b036-67ec48b7956c	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
023c32c5-31ea-448c-be00-91cfbfb6aa42	97642c0e-6ff8-4d75-b036-67ec48b7956c	12	2	0.385	339dee6f-1d8f-482c-8465-a87d2650af5e
935e58a9-cf8b-4739-8c66-a0eeb63a14c7	97642c0e-6ff8-4d75-b036-67ec48b7956c	12	3	3.078	339dee6f-1d8f-482c-8465-a87d2650af5e
02b2a083-a3e1-4a67-8434-7bc5ebdb3c86	97642c0e-6ff8-4d75-b036-67ec48b7956c	12	4	3.847	339dee6f-1d8f-482c-8465-a87d2650af5e
38497d46-df9a-43a0-a77c-a5521664b242	97642c0e-6ff8-4d75-b036-67ec48b7956c	12	5	0.192	339dee6f-1d8f-482c-8465-a87d2650af5e
45ce851e-c699-453c-8880-302830a6b684	97642c0e-6ff8-4d75-b036-67ec48b7956c	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d79e7664-6a88-4dab-8080-3949be1c1ee7	97642c0e-6ff8-4d75-b036-67ec48b7956c	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8f2f2b60-f1a9-4e8b-9b05-ef12ef287aca	97642c0e-6ff8-4d75-b036-67ec48b7956c	13	3	0.923	339dee6f-1d8f-482c-8465-a87d2650af5e
09df349f-8e93-4ed0-8c98-c1a5db8e5af4	97642c0e-6ff8-4d75-b036-67ec48b7956c	13	4	1.108	339dee6f-1d8f-482c-8465-a87d2650af5e
80a2b471-bb63-4c0f-9e97-b346ee46abf0	97642c0e-6ff8-4d75-b036-67ec48b7956c	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ed8549a5-8d43-4e0f-8823-b272a32c79ad	97642c0e-6ff8-4d75-b036-67ec48b7956c	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d91a293c-5ad9-46e6-8da0-90a20a61d726	97642c0e-6ff8-4d75-b036-67ec48b7956c	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bab93961-d856-4d48-a843-6429fa82d6cb	97642c0e-6ff8-4d75-b036-67ec48b7956c	14	3	0.115	339dee6f-1d8f-482c-8465-a87d2650af5e
9a33fb70-16dd-4a8e-becd-b37f7642eba9	97642c0e-6ff8-4d75-b036-67ec48b7956c	14	4	0.115	339dee6f-1d8f-482c-8465-a87d2650af5e
5bdbc122-04c1-4ca8-944d-d82648df0a6e	97642c0e-6ff8-4d75-b036-67ec48b7956c	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c5032acd-23ae-49e6-83f0-e40dab9e26ae	97642c0e-6ff8-4d75-b036-67ec48b7956c	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
73928c25-f0ef-4185-a6e5-2ae389b9bed1	97642c0e-6ff8-4d75-b036-67ec48b7956c	15	2	0.231	339dee6f-1d8f-482c-8465-a87d2650af5e
dfb6b2bc-21b7-40ea-8ea3-10de5a302a02	97642c0e-6ff8-4d75-b036-67ec48b7956c	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
37f5e35a-1bc6-4198-88c1-30a67be70c49	97642c0e-6ff8-4d75-b036-67ec48b7956c	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1d6b8058-55d2-4bc3-86f7-153979d2462d	97642c0e-6ff8-4d75-b036-67ec48b7956c	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0786383e-ecda-4c9e-a430-0cdef3ebff1d	97642c0e-6ff8-4d75-b036-67ec48b7956c	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ea3cfe2a-26b1-4fbc-9524-2b877b359155	97642c0e-6ff8-4d75-b036-67ec48b7956c	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d07d5b0f-79f8-40bc-b368-20f93f2599b6	97642c0e-6ff8-4d75-b036-67ec48b7956c	16	3	0.231	339dee6f-1d8f-482c-8465-a87d2650af5e
e2cbdacf-10b6-4a92-8954-240e07aa0407	97642c0e-6ff8-4d75-b036-67ec48b7956c	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4fcd07d4-f036-455d-98e7-7cfeb3cb6409	97642c0e-6ff8-4d75-b036-67ec48b7956c	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
47077786-78e5-41b3-a1b0-7c843c339d60	97642c0e-6ff8-4d75-b036-67ec48b7956c	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ccc67608-befd-47b6-8570-e970147d7d1c	97642c0e-6ff8-4d75-b036-67ec48b7956c	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
92468c3c-949d-4b82-a004-2245b5584658	97642c0e-6ff8-4d75-b036-67ec48b7956c	17	3	0.308	339dee6f-1d8f-482c-8465-a87d2650af5e
f7ebb1e0-6a7d-46f4-9d22-7ae6b64a2392	97642c0e-6ff8-4d75-b036-67ec48b7956c	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
25ef9343-b9d8-43ff-9a5b-a1395338c319	97642c0e-6ff8-4d75-b036-67ec48b7956c	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
76c96046-b51a-43d0-bb4a-3d6b3d251b50	97642c0e-6ff8-4d75-b036-67ec48b7956c	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
88c43540-86e9-4c24-9203-d2badfdf9452	97642c0e-6ff8-4d75-b036-67ec48b7956c	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8241984c-b891-4127-b5ad-061087e18140	97642c0e-6ff8-4d75-b036-67ec48b7956c	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c67d87d0-2605-4d95-bc77-d68d8f0d17ca	97642c0e-6ff8-4d75-b036-67ec48b7956c	18	4	0.231	339dee6f-1d8f-482c-8465-a87d2650af5e
a24c9b4b-b91c-4465-b47b-1e99b5b00fbd	97642c0e-6ff8-4d75-b036-67ec48b7956c	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
315cabcc-6dcc-4a89-8792-755ae1846d27	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	1	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
85400fc7-106f-43d5-aa59-052d2f4f57f4	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	2	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
07d3449e-750e-47de-8f05-9289c09713cf	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	3	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
0232b4fa-ffeb-4046-ae97-9314b01db62b	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	4	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
6ad23e6a-b9a0-4d2b-b9b5-e7c8c02b5d7e	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	5	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
61bbe315-104a-4f0f-8802-ecb84ec95757	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	1	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
9fbb897d-a3d7-4cf7-ba54-b3762967f512	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	2	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
c03d5168-1821-43f4-a7ac-70bc9122f45e	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	3	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
61ee8bc8-d9fa-433d-982f-43e2538dbd60	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	4	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
2472e101-52fe-48ae-a5d1-9c622d8b271b	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	5	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
1363b20b-e793-4f74-9666-4694a6d55e42	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	1	0.043	339dee6f-1d8f-482c-8465-a87d2650af5e
8d75b8d9-52ff-4d53-85b6-3086f6a7179a	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	2	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
7a1fe4b6-19cd-40b3-a7ee-079362384bae	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	3	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
c9a3dfd3-353d-4ca0-8dc9-9d6a83631504	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bcdc6b8d-8e90-442e-86ae-7614b0b6fd6a	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f0229e8f-b191-4b47-b36e-5568fe339dac	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ec0f2a8b-4110-4c22-bc81-469470f71a0e	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	2	0.141	339dee6f-1d8f-482c-8465-a87d2650af5e
f4003f31-dff7-4735-ae3e-6f18022a9880	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	3	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
1862f938-9742-425f-9c36-ae9de71c02be	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	4	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
ace64ab6-4709-44c8-9836-e2d696f49653	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	5	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
b14395e5-e379-4864-88f7-ef1c77b303e7	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
215af38e-c4d7-4ba0-834a-d3adb5123373	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	5	2	0.423	339dee6f-1d8f-482c-8465-a87d2650af5e
048891ee-d688-48a8-85f9-6f41f02f985f	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	5	3	0.846	339dee6f-1d8f-482c-8465-a87d2650af5e
16d80180-86a3-4f94-b379-58b302f135f4	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	5	4	0.846	339dee6f-1d8f-482c-8465-a87d2650af5e
5b05ed7d-d107-4ef6-ad36-f4efa5c2f1cd	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	5	5	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
4d713e09-9ba2-4653-912d-f369b5be1871	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
259b9339-4d52-4448-ab47-933688d0b969	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
62bf1e4a-7d7f-4f1f-bbad-f47ecd0d9f91	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	6	3	0.603	339dee6f-1d8f-482c-8465-a87d2650af5e
42cb21c2-25ac-4809-bbec-23bfd4cc682c	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	6	4	0.931	339dee6f-1d8f-482c-8465-a87d2650af5e
e496cfe1-31eb-4681-b361-2860d8f196bb	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	6	5	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
9391b446-7b3c-4b60-a2cd-1f41cbf7fd64	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	7	1	0.241	339dee6f-1d8f-482c-8465-a87d2650af5e
5e3b8203-a713-4210-86b7-30a60a029358	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	7	2	0.517	339dee6f-1d8f-482c-8465-a87d2650af5e
2f21b49f-6c57-48cc-abba-0d8bb23f5b24	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	7	3	0.517	339dee6f-1d8f-482c-8465-a87d2650af5e
6d3d686b-6d5a-42b8-b317-0982f61ae3fd	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	7	4	0.259	339dee6f-1d8f-482c-8465-a87d2650af5e
8a661079-6ac3-42e5-bede-c375714bca0c	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	7	5	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
4998617c-6c6c-49c6-bd26-7276e8e3358b	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	8	1	0.241	339dee6f-1d8f-482c-8465-a87d2650af5e
16387a23-9ac3-4661-8aca-f286deed34bd	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	8	2	0.517	339dee6f-1d8f-482c-8465-a87d2650af5e
0cf91840-7102-4039-b38d-62357b3bad1c	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	8	3	0.517	339dee6f-1d8f-482c-8465-a87d2650af5e
a2d9abb5-bc1d-44ff-a3c2-47be51ae82d5	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	8	4	0.259	339dee6f-1d8f-482c-8465-a87d2650af5e
793a3bb6-beb8-4355-b755-de19e9e03506	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	8	5	0.172	339dee6f-1d8f-482c-8465-a87d2650af5e
96a64a0d-17b6-44f8-95ab-ae6d00766204	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e5f4a158-7d45-4b8d-8b35-21cc957e6c17	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
37fc2f39-8979-4758-ab26-aeef1d02f4a4	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
503014db-ca1f-44c0-99c0-05d2d9baa813	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b3b99c2-26d9-4c50-9e86-8ca422077797	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
087e88e8-d543-40fb-aa4a-c98a5853171b	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a2c1830f-f1b6-4383-af22-b61c1c3870ae	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	10	2	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
147f977d-3082-4bc1-93f5-935127181ebe	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	10	3	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
e7104afd-6ec5-4bb6-b21b-b4a7a2fa1719	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	10	4	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
79644726-dffb-4578-ab93-bef540ac5b62	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	10	5	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
54a69341-539a-44a5-b427-5beba6d0f9b4	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	11	1	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
c96f17c9-abd7-465c-8376-3167ce88b3fc	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	11	2	0.113	339dee6f-1d8f-482c-8465-a87d2650af5e
e88f22ed-9c1d-42dc-9a7a-0cceb2aa11ed	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	11	3	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
8e9b2392-6922-46f7-81af-19f95967dd72	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	11	4	0.282	339dee6f-1d8f-482c-8465-a87d2650af5e
bec04251-f681-4d41-9acd-f6825169eca0	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	11	5	0.070	339dee6f-1d8f-482c-8465-a87d2650af5e
ed736fb3-d243-427a-bfd8-31a37c342cb4	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3f997370-9b2d-4433-ba26-b326b74131ab	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	12	2	0.108	339dee6f-1d8f-482c-8465-a87d2650af5e
183f3900-3bd6-49f8-82cb-bb6c0a0a7208	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	12	3	0.862	339dee6f-1d8f-482c-8465-a87d2650af5e
a43fe0e5-1bf7-47b4-9e25-21ad21586a9c	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	12	4	1.078	339dee6f-1d8f-482c-8465-a87d2650af5e
f455499d-64ac-44ef-838c-7735b0114500	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	12	5	0.054	339dee6f-1d8f-482c-8465-a87d2650af5e
0692d168-b16b-4ac9-892d-20de3f9f4e97	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3f16c501-6e84-4bad-b296-a9a24a37c2e4	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7ffc4219-7d9e-479f-981a-67ee5c725821	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	13	3	0.388	339dee6f-1d8f-482c-8465-a87d2650af5e
3609ff28-86c0-4ffc-a75b-b61e5b20865f	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	13	4	0.388	339dee6f-1d8f-482c-8465-a87d2650af5e
85fe2587-0c9d-4695-afb5-a5f90e7393f2	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
13be6cee-26e7-43c9-8b2b-55264937ea53	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
be844802-3f15-4d8c-9d77-263fe072114e	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
64f6a8b0-f9d7-4cea-a7df-623393cfb345	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	14	3	0.032	339dee6f-1d8f-482c-8465-a87d2650af5e
39c4146a-8cda-4ec9-95b5-ce4d2f50df88	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	14	4	0.032	339dee6f-1d8f-482c-8465-a87d2650af5e
1d9f549c-e8a5-4905-adc9-ec11e7bf7032	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bacab612-7abb-41b5-8f03-288a81384a96	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7dd89861-2232-4db0-a5a8-a29e766f61af	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	15	2	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
456f153f-4533-4010-8920-20a9d43fdfc7	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d376187e-b289-4162-b9d2-fa6f73eb46ab	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d56b6349-6136-4297-9819-da4b515347b2	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1793152f-7ad6-4743-ad84-d8276af8a57c	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cd6d2e54-d019-4023-bb60-bbc3ea1583ff	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
95f9c387-9a0c-4ef2-baeb-5f4b46282b02	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	16	3	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
04021c89-76e6-4b13-b4e8-ecdf03013d60	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
aa3934e3-4a34-4fea-abe6-bf6530341c94	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af5e89ce-6804-4261-ae36-4cd2cb2f5ee5	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6f1cfd88-6743-4014-9b7a-583fd6e86850	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6da6ede4-23ef-4362-a72f-d6f22e6c50ab	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	17	3	0.086	339dee6f-1d8f-482c-8465-a87d2650af5e
0e4efd2a-17b6-45d7-909c-26791b7639a6	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
19399bb0-db88-47d2-bcd2-ddd39ec01046	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4fb9e18a-8703-4136-bc01-4fda584b9fff	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
69d12246-2ede-4d95-a5fb-9406bf343f4c	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
da777363-4ecc-4624-a83c-974cfbf72b55	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0fe528f7-0cbd-4a9d-af07-e0e3a2b655b8	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	18	4	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
c2e0c6cd-7067-4972-abb7-3d0318aa879e	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7149499f-d4d4-4526-9e01-19c621dabf9d	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	1	0.665	339dee6f-1d8f-482c-8465-a87d2650af5e
1c33036d-8843-4589-8d1b-4c4178f6a914	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	2	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
1aefbcd0-b18c-4819-b929-c5f1097bce34	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
87d2c9f2-72d1-4fc5-9eb5-7e3ca212e084	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
a524e6e2-2303-46a0-8689-f9daadc03554	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	5	0.443	339dee6f-1d8f-482c-8465-a87d2650af5e
0168bebf-d798-41b1-abf2-f8673913ad34	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	1	0.665	339dee6f-1d8f-482c-8465-a87d2650af5e
9924937d-8a3f-4ada-8c56-1106865293ac	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	2	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
c6fb10bf-8fb2-4011-8d7f-929ce9527598	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
6f5c5b98-3f87-4916-b6dd-6f8e64a28bef	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
295d1039-5ed1-4c63-b70c-5f7507e78c0b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	5	0.443	339dee6f-1d8f-482c-8465-a87d2650af5e
7f6608fa-7335-4051-b5a9-84a89cfc6f6f	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	1	0.854	339dee6f-1d8f-482c-8465-a87d2650af5e
5c735bdf-277c-4960-83e1-e8e58add74f4	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	2	0.427	339dee6f-1d8f-482c-8465-a87d2650af5e
ec276a4f-187a-483c-af0d-80a31f962bcd	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	3	0.427	339dee6f-1d8f-482c-8465-a87d2650af5e
eb188ffd-b95f-43c2-a89e-d708ae29926b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	4	0.427	339dee6f-1d8f-482c-8465-a87d2650af5e
70f728bf-3723-4d8f-9913-41f8c8c9fbf9	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	5	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
32e717f3-43e3-4285-b2ad-6cfdc09352bc	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7f479e5c-3b77-414a-a3d7-7b8d1de31999	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	2	0.443	339dee6f-1d8f-482c-8465-a87d2650af5e
cc44979d-88c9-47c2-8bf5-1e0f279f3e6b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
3f6b91c3-db18-47c9-8462-2b87d9a5a25b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
07f86e24-512e-4151-adc3-29b4433be298	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
4585a1d8-2619-4dc6-b850-a78ffb78238b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cfb46d04-c3cc-4d2d-8d20-439617f43589	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	2	1.330	339dee6f-1d8f-482c-8465-a87d2650af5e
43540dcb-30e3-4fa3-b4a1-419ebcee87e7	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	3	2.660	339dee6f-1d8f-482c-8465-a87d2650af5e
b3fdb9ea-ebc8-4060-9760-b741ed572d38	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	4	2.660	339dee6f-1d8f-482c-8465-a87d2650af5e
367f076a-e436-4bb4-87f6-0f240e5be810	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	5	0.665	339dee6f-1d8f-482c-8465-a87d2650af5e
379e70ce-6955-430c-8281-f99e06d89b69	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f04a3f11-abad-42c6-9e9c-5b45c4081490	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3c456f44-3021-4d71-a018-9a96a20679ac	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	6	3	5.551	339dee6f-1d8f-482c-8465-a87d2650af5e
acca7e12-4264-4752-8403-dc35efa0e86a	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	6	4	6.405	339dee6f-1d8f-482c-8465-a87d2650af5e
fb096abd-4ffd-4749-bf1a-6d7955193607	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	6	5	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
f3e13692-7074-4696-9b78-b4af1f7a2ccf	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	7	1	0.747	339dee6f-1d8f-482c-8465-a87d2650af5e
59db39fc-b202-453f-b19b-b6dd8fb4c5ff	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	7	2	3.843	339dee6f-1d8f-482c-8465-a87d2650af5e
ce11663b-4aec-401d-8742-c2046c10a658	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	7	3	2.135	339dee6f-1d8f-482c-8465-a87d2650af5e
8c65c0dc-e99f-4785-bff9-6f5081ae116c	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	7	4	1.067	339dee6f-1d8f-482c-8465-a87d2650af5e
24aa9ee2-1537-4cc9-ae68-d147222f1d6e	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	7	5	0.427	339dee6f-1d8f-482c-8465-a87d2650af5e
4cd28a53-490c-4704-994e-d50c47df2dc0	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
84b66c4d-05b2-440e-9188-721055107a3d	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ac4d6c14-54b1-436a-98e5-c033e420402b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6c66017c-89d7-4c96-80dc-50f85adf22fe	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c1e353b5-e0ce-4427-a9cf-b2db215571cb	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
76fa01e5-1c01-456f-8f6d-a6d07147aa01	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
42852b89-9c13-4368-bbbc-179eedf8e62b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b15360f-ee7a-4f17-8e85-6fd3e1660b9c	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c11200cf-d6c2-48f5-becf-dfa8c901adc0	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8f8c6c6f-4f01-4092-8aea-e0959564e86c	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
016f73a4-0d8a-4ae4-a1eb-6feea96d14e4	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1769e1b6-d1b5-4ab8-b9f8-9ede0019e320	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	10	2	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
de68f4eb-e670-47e5-95cc-e04dc185517d	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	10	3	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
398a649b-2a98-4a6a-b6c7-0ab8929bbc76	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	10	4	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
73b289c5-f854-4e8d-b28c-edc975a24a27	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	10	5	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
2e00446c-ccf6-4163-b0e0-088e1fdeb96f	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	11	1	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
107d3386-3040-4f1d-9cf8-ae3f2c7b6354	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	11	2	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
b18de2ee-0aa1-4694-b036-f9277d3d63d2	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	11	3	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
d74e2bca-8c05-4151-a0f1-f16dbf4ee0ae	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	11	4	0.887	339dee6f-1d8f-482c-8465-a87d2650af5e
e039a79c-56ea-40b5-a5b1-3aad0e82c094	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	11	5	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
8c8892ec-f2f4-4316-835d-d3b2a0a18988	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6cabca12-4047-4e36-bde0-cd124170169d	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	12	2	1.708	339dee6f-1d8f-482c-8465-a87d2650af5e
20a33fe5-e577-4627-b52b-f76446297f8a	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	12	3	3.416	339dee6f-1d8f-482c-8465-a87d2650af5e
4c8e226e-598d-41ee-9c99-cb151c2a9b48	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	12	4	4.270	339dee6f-1d8f-482c-8465-a87d2650af5e
aefa8532-5a84-44d4-886e-c25f4d56d0c2	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	12	5	0.213	339dee6f-1d8f-482c-8465-a87d2650af5e
8b4175f2-6110-4eb0-9561-76def2ed8dfd	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9a5d4f8e-05fd-4a53-ba76-9b08c1890575	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ae8f35db-be0b-4447-bf6d-1043bf83866b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	13	3	2.562	339dee6f-1d8f-482c-8465-a87d2650af5e
2336552d-67ec-4d56-b3ca-ea5a406b9554	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	13	4	4.270	339dee6f-1d8f-482c-8465-a87d2650af5e
aecb1fc8-a3f2-4c29-bd38-16ab239957e4	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0f592343-178c-4da7-b5c0-7fff964e803f	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
27244b84-76da-49b3-8dca-7030a30a2b6c	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2217c8b7-99c7-4cc0-847e-74f1502e5a65	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	14	3	0.640	339dee6f-1d8f-482c-8465-a87d2650af5e
7c2c86ac-a801-47e9-ab54-e767d8ef9218	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	14	4	0.640	339dee6f-1d8f-482c-8465-a87d2650af5e
96bf9033-0491-4cdd-88a5-3d39e52cd420	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3df16bba-a273-4741-8af3-f8ea90327c5f	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0b5d2106-443e-4674-ac8e-dff984e7995b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	15	2	0.480	339dee6f-1d8f-482c-8465-a87d2650af5e
a20d687d-902f-4349-bc4e-e664e3921abc	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9ccc0fd1-5dd9-48c8-94b2-eca7f5ad0379	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
04ae0a5d-f3c1-43de-9537-28047958cf9b	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7a226947-91f4-4448-a2ed-d5c7eebbf75e	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
84e4c88a-81ce-4f99-bd83-03bc38ea9a9e	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
353a39ed-184d-4040-a62c-ddf12a76da1a	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	16	3	0.961	339dee6f-1d8f-482c-8465-a87d2650af5e
4a8aeacc-2d26-4411-b5d7-eeaca6853bd4	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b299850-571b-4e3a-a99b-47d5c7c0e379	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9e39304c-a875-4b3e-a114-a8514483e6f9	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
536cb5af-2d22-4521-ad78-abaa7888b784	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d2058327-181a-4edf-8901-927f60588563	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	17	3	3.202	339dee6f-1d8f-482c-8465-a87d2650af5e
7e3844d6-76c7-48e2-b1d6-418e6f517d83	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0efae34b-ddc9-4321-9bc5-0407a0bbac91	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8137821f-65fc-485c-97f1-613a8a90d63c	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
514ba51f-ba86-48fe-900c-49ee874971d0	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6e184817-1b6e-46df-b5a4-ba43062a9a1a	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
21bf84f5-6fc2-482d-ae6d-5bd77f0423ab	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	18	4	0.427	339dee6f-1d8f-482c-8465-a87d2650af5e
08ca411f-ba85-4d8c-9735-d97a75d5bfd2	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bc954dca-08eb-4d58-b535-b19d143c01ad	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	1	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
f7b9810f-6cfd-4770-be8c-c251018e8fc5	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	2	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
6534d041-af17-45c2-9e7f-122bda14257e	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
15f6a21b-9c26-4beb-ab4e-a9163f6d0023	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
0f56facd-e80b-4b22-b130-d7c9e54ff0d4	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
21bfe3fa-337d-48dc-a422-acfe61f7ad51	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	1	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
1183f51b-87fb-473e-bda4-1db8f0e55006	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	2	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
41784425-913f-4b73-8eb7-fdcee391f259	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
245700b4-38b1-4d6e-99a2-e7a94f3f81d5	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
e1935e2f-a609-4153-8192-9c4b3b000d90	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
fb61008a-10fd-4054-b957-9877ab5f371a	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	1	0.222	339dee6f-1d8f-482c-8465-a87d2650af5e
788c200b-07dc-4a08-ae99-78c76d681247	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	2	0.266	339dee6f-1d8f-482c-8465-a87d2650af5e
dfa599eb-9e1c-4e98-9ca7-fef7a3962fe5	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	3	0.266	339dee6f-1d8f-482c-8465-a87d2650af5e
db418b80-2f66-40b3-a50c-60b345f272ca	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
36185499-d77d-4440-a981-5ccedf2169a4	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4f87326d-19eb-48f8-b8d4-3017dddbdf6f	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2b266228-04da-4ebe-81a5-fde8a4d43a35	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	2	0.452	339dee6f-1d8f-482c-8465-a87d2650af5e
822f3f0a-359d-4ec8-9612-fb411629f3d9	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
0ae5a77b-0a8d-4598-acb5-810ee09d791a	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
34fc8a73-a648-432e-abd7-66be254aec98	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
20807348-bc9c-4ab4-8907-3835dd8b674c	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
21cd63fa-34c3-429f-a304-6678d2b3b833	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	2	1.356	339dee6f-1d8f-482c-8465-a87d2650af5e
b8d27cf3-a027-49de-84ae-93e10d410c90	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	3	2.713	339dee6f-1d8f-482c-8465-a87d2650af5e
579220c5-6fb4-4a5a-9e1a-8c31905bb71b	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	4	2.713	339dee6f-1d8f-482c-8465-a87d2650af5e
56e69b40-28a5-463d-b03a-2cc5d265369d	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	5	0.678	339dee6f-1d8f-482c-8465-a87d2650af5e
ea5a3c29-7d04-4423-bf36-ac871c14d7ba	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af1b27e6-7e3d-45e3-a160-9a35d82bcf43	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3646d5a4-cf70-4c6d-aef8-9ff8a1a34fe1	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	6	3	3.107	339dee6f-1d8f-482c-8465-a87d2650af5e
832423e1-78ea-4d6c-97e2-08f7a7e5275c	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	6	4	4.794	339dee6f-1d8f-482c-8465-a87d2650af5e
43006e06-2ab2-4325-a2aa-868a1cb46735	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	6	5	0.888	339dee6f-1d8f-482c-8465-a87d2650af5e
b6aadaff-d7c7-403a-9ae9-7855605d794b	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	7	1	1.243	339dee6f-1d8f-482c-8465-a87d2650af5e
395a9137-4a69-4fea-bf79-ab76803c9957	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	7	2	2.663	339dee6f-1d8f-482c-8465-a87d2650af5e
382122fd-e676-44c9-8023-41d66cb87dda	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	7	3	2.663	339dee6f-1d8f-482c-8465-a87d2650af5e
b8dd14f1-aef1-46f2-b1e6-b1e9f5b5e191	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	7	4	1.332	339dee6f-1d8f-482c-8465-a87d2650af5e
7a405761-243b-4d01-95c1-78585c9cf5f7	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	7	5	0.888	339dee6f-1d8f-482c-8465-a87d2650af5e
db3b156c-3a7a-41db-aa0c-97dd9ce2b85b	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	8	1	1.243	339dee6f-1d8f-482c-8465-a87d2650af5e
bfba907a-0438-47e5-8037-199f53646d6b	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	8	2	2.663	339dee6f-1d8f-482c-8465-a87d2650af5e
1b20be44-dc76-4795-a809-be3453af4958	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	8	3	2.663	339dee6f-1d8f-482c-8465-a87d2650af5e
f5573342-6dd0-48ef-a22c-ebb7491544db	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	8	4	1.332	339dee6f-1d8f-482c-8465-a87d2650af5e
4c0d55da-97af-40d7-85d9-72a4f75d1644	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	8	5	0.888	339dee6f-1d8f-482c-8465-a87d2650af5e
16755a0f-515d-40c5-927f-7f481b3e590d	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
31ec260d-a4e8-4948-a870-91e553620d11	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f2c809cd-85f7-4fb9-98e0-26b1dd452b13	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8f3a6bbd-7380-4a77-b84f-a4c77f468f36	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
17f15ecc-7b50-46e8-99aa-ba759d8d1700	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5a4e5637-89db-4b8e-a886-4703bc45186f	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ee81da1b-f41f-4444-9a0e-261ba3b3e09f	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	10	2	0.444	339dee6f-1d8f-482c-8465-a87d2650af5e
df7a6466-e19e-44f2-8e54-9e3d525d9069	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	10	3	0.444	339dee6f-1d8f-482c-8465-a87d2650af5e
e11a684f-37dd-422d-85b8-04599846b78c	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	10	4	0.444	339dee6f-1d8f-482c-8465-a87d2650af5e
09965f90-1834-4e42-ab9e-b88a9f740c83	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	10	5	0.444	339dee6f-1d8f-482c-8465-a87d2650af5e
d2228b3e-2e4f-4236-a6b9-d763ea3397cd	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	11	1	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
4551dc99-6b2e-480f-8f9b-e1ad28009cb7	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	11	2	0.362	339dee6f-1d8f-482c-8465-a87d2650af5e
a7045588-3786-4d99-81ed-e042b3ae6da3	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	11	3	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
96a4e2b8-90c1-495a-984d-30ac5adbe7e2	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	11	4	0.904	339dee6f-1d8f-482c-8465-a87d2650af5e
a9826ac5-a1e0-4996-9aaf-9cef935a2039	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	11	5	0.226	339dee6f-1d8f-482c-8465-a87d2650af5e
bdf50cba-ccd6-4a17-90ad-c91c90805c78	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b64ae49b-e680-419f-ba8b-a0e92e4d6dcc	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	12	2	0.555	339dee6f-1d8f-482c-8465-a87d2650af5e
5f7e2d79-f2f5-4136-8555-e23d812de827	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	12	3	4.439	339dee6f-1d8f-482c-8465-a87d2650af5e
e3564f52-291f-4f26-9ff3-657799dcad68	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	12	4	5.549	339dee6f-1d8f-482c-8465-a87d2650af5e
969f7f7e-74b0-48d7-89fb-c70dd2f13166	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	12	5	0.277	339dee6f-1d8f-482c-8465-a87d2650af5e
acf29ff2-ee8d-4991-bbf2-019eafbb4b61	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
eefb6ad8-c306-4ea3-8755-7d5bcaa8d4ee	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
06ca4107-1ca9-47d9-a29b-b9f791963109	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	13	3	1.998	339dee6f-1d8f-482c-8465-a87d2650af5e
a4a089e4-b15b-434f-ad75-c1bf55333628	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	13	4	1.998	339dee6f-1d8f-482c-8465-a87d2650af5e
a99871d5-5781-41e2-8e09-8edb0c5325ed	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
69a129e3-cbc6-4a71-8bdb-dc93ba93bb91	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
25588144-2771-45ce-8559-f97c3a41eacc	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
74e07d7a-09b0-4855-82b4-73b3081f2657	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	14	3	0.166	339dee6f-1d8f-482c-8465-a87d2650af5e
a5c9e2ee-51ad-4026-8f5f-22b407de7784	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	14	4	0.166	339dee6f-1d8f-482c-8465-a87d2650af5e
3a676bee-c39b-47ab-8b47-358bef2aa83e	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a46d6b2d-5418-46bf-bce7-2333c347527d	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3cdcfbb7-088d-4125-902d-bad72d5a5a07	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	15	2	0.333	339dee6f-1d8f-482c-8465-a87d2650af5e
2805c2e1-c103-4970-9232-0582c59440fa	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
db127681-7c3d-4d17-a677-df36d22adb4e	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
92fd29ea-8c6a-4ce1-a197-353364528c0c	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9bc7a9fe-b718-4ca6-b38b-a2367c1a69c2	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fccb9a73-042a-47f1-915b-97b162c0d2e1	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fec3746d-8cd7-4a07-a93e-6a04133b5221	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	16	3	0.333	339dee6f-1d8f-482c-8465-a87d2650af5e
576d8cc0-5f7a-4526-a854-a572a6ee8c50	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
afb0e38c-fba7-4c3c-89e1-e9217f315fea	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5358831b-4945-4bec-9b61-e792c3422824	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5290bdce-f3fb-46cb-ab25-8a45345df66e	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a7060d88-f1c3-4e13-b5bc-e6dbb6919560	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	17	3	0.444	339dee6f-1d8f-482c-8465-a87d2650af5e
fc73daf4-3daf-4b93-bf85-fee5737fcee4	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e0827f94-489f-4213-afc8-f40aa9a0fc33	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bb579a94-a4cb-47b1-ac38-24652ff8bc8c	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6d2c316b-8281-41e0-ae55-5e9eb4004f16	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a20ffb4f-0303-4c5d-bf6b-634d980bf052	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
56e3ba46-7936-4083-902e-95cfbc746f27	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	18	4	0.333	339dee6f-1d8f-482c-8465-a87d2650af5e
12470e58-27a7-4d29-9d5c-3d7fb4e6e954	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7eed7f59-b10d-47ca-998e-e5972a913748	0645fe54-ce1a-4ed5-b54c-727c2abf3814	1	1	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
172a8833-8f84-4793-829a-15ac2a4f85ba	0645fe54-ce1a-4ed5-b54c-727c2abf3814	1	2	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
6da2f9a1-b2ea-4c87-a29e-53bd0b99ad5e	0645fe54-ce1a-4ed5-b54c-727c2abf3814	1	3	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
9665fc68-a0fd-4f5a-bdd4-2da01bdfd36b	0645fe54-ce1a-4ed5-b54c-727c2abf3814	1	4	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
f04c494e-2598-4bf3-bfe4-09633664f8ef	0645fe54-ce1a-4ed5-b54c-727c2abf3814	1	5	0.049	339dee6f-1d8f-482c-8465-a87d2650af5e
63dcf5a3-0d78-40fa-9e10-81a2166a1060	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	1	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
bf06d1c4-be34-49a7-a4e7-ceb57cf09b99	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	2	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
f5e530c2-2b7e-4ad7-b337-3e9374a20752	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	3	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
6a815dd8-d7c1-41c3-b513-ec0a3079604d	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	4	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
70b06aee-cc4a-43cb-b6bc-7d8a0c25e4bd	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	5	0.049	339dee6f-1d8f-482c-8465-a87d2650af5e
9867e8fb-f7cd-4c92-829f-2b20504a1982	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	1	0.050	339dee6f-1d8f-482c-8465-a87d2650af5e
af17f3ae-6c53-4417-aa0d-9b949f268028	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	2	0.060	339dee6f-1d8f-482c-8465-a87d2650af5e
4ec4b1a1-f4e0-4a28-9799-80d82ae567ac	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e9d4fe4b-ef7e-4222-a954-f285eef857ee	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c143f269-39e0-40aa-bba7-ed47b4580059	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
29b68e51-b191-4b4d-8f26-a8f07d05047f	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
47908036-c647-491f-b8d6-32687ecbe368	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	2	0.097	339dee6f-1d8f-482c-8465-a87d2650af5e
d082388a-b726-4e1b-8bdd-8edad8990e5a	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	3	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
2b0a644f-2a71-4a6d-aa35-7c731dd6eb1f	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	4	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
e2ee4caf-6faa-4f79-836d-b29af0edb2af	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	5	0.049	339dee6f-1d8f-482c-8465-a87d2650af5e
9559f684-f58f-4330-93bd-362951bbf1a2	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
29aa80c5-f7a2-4b57-9568-ae719543658e	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	2	0.292	339dee6f-1d8f-482c-8465-a87d2650af5e
c3527213-c359-48a0-bd8f-3c14e88d5c60	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	3	0.583	339dee6f-1d8f-482c-8465-a87d2650af5e
d7688cf2-4dc9-433e-b366-49b719eeaebf	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	4	0.583	339dee6f-1d8f-482c-8465-a87d2650af5e
04916152-1b5d-406b-8e78-028f34cd2150	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	5	0.073	339dee6f-1d8f-482c-8465-a87d2650af5e
829c34c4-debc-46bc-8335-54f7dd8d5d3d	0645fe54-ce1a-4ed5-b54c-727c2abf3814	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7bed3916-9414-45d8-ba22-34cea3f54914	0645fe54-ce1a-4ed5-b54c-727c2abf3814	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
03ecd099-0972-4b06-874a-ac10360c82cb	0645fe54-ce1a-4ed5-b54c-727c2abf3814	6	3	0.325	339dee6f-1d8f-482c-8465-a87d2650af5e
976134f1-e5a3-4554-8649-39ac628cb15b	0645fe54-ce1a-4ed5-b54c-727c2abf3814	6	4	0.749	339dee6f-1d8f-482c-8465-a87d2650af5e
fe3b380a-f086-404e-9922-1e6c529499e0	0645fe54-ce1a-4ed5-b54c-727c2abf3814	6	5	0.050	339dee6f-1d8f-482c-8465-a87d2650af5e
d89be3ff-3487-4aa9-a5f4-8943f325765c	0645fe54-ce1a-4ed5-b54c-727c2abf3814	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82659145-63b1-4213-9ff6-e4750b6d3b75	0645fe54-ce1a-4ed5-b54c-727c2abf3814	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bc67ca1e-ef93-41c0-9b4a-b3fecb4b38a6	0645fe54-ce1a-4ed5-b54c-727c2abf3814	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ef0921be-0f0d-44e0-a9e9-fab4dbeade97	0645fe54-ce1a-4ed5-b54c-727c2abf3814	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
25e610d2-315f-4a76-84c5-9df339e21b46	0645fe54-ce1a-4ed5-b54c-727c2abf3814	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0140d2db-64fa-4020-b182-17e5ee3f9e33	0645fe54-ce1a-4ed5-b54c-727c2abf3814	8	1	0.175	339dee6f-1d8f-482c-8465-a87d2650af5e
9765c974-94af-463c-98be-16493baebc47	0645fe54-ce1a-4ed5-b54c-727c2abf3814	8	2	0.499	339dee6f-1d8f-482c-8465-a87d2650af5e
3da012a0-c96f-4da3-83f9-25fb9111f5bf	0645fe54-ce1a-4ed5-b54c-727c2abf3814	8	3	0.499	339dee6f-1d8f-482c-8465-a87d2650af5e
3a4e2abf-4f5e-4a1f-a675-22e899fd515f	0645fe54-ce1a-4ed5-b54c-727c2abf3814	8	4	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
9cb996ee-dd4d-4154-ac0f-2556e8dec5d5	0645fe54-ce1a-4ed5-b54c-727c2abf3814	8	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
263a8aeb-d56f-4eca-b13a-706b2b95b876	0645fe54-ce1a-4ed5-b54c-727c2abf3814	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ee875ded-a7e1-42d2-b588-4ac60e76a1c2	0645fe54-ce1a-4ed5-b54c-727c2abf3814	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
291efc48-bd9b-41b9-bd5a-860856b19a7a	0645fe54-ce1a-4ed5-b54c-727c2abf3814	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5367d5ec-16d7-4f2d-a129-3ade302cfc45	0645fe54-ce1a-4ed5-b54c-727c2abf3814	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
20038587-d6e2-4314-a8e6-d23fb85c1132	0645fe54-ce1a-4ed5-b54c-727c2abf3814	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c97b676f-f4fe-4fc7-abe2-68ae76a41ee8	0645fe54-ce1a-4ed5-b54c-727c2abf3814	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
377a9769-999e-4a02-b17e-239da1f9e235	0645fe54-ce1a-4ed5-b54c-727c2abf3814	10	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d39cb9b5-c897-44a2-9bb7-d71e0c1df14d	0645fe54-ce1a-4ed5-b54c-727c2abf3814	10	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54ddd5f8-b6aa-40e1-b18c-c2e4a5f9ca68	0645fe54-ce1a-4ed5-b54c-727c2abf3814	10	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d2322292-08ef-4883-9754-d2864a627b10	0645fe54-ce1a-4ed5-b54c-727c2abf3814	10	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b0e0087f-5f66-469c-8a71-8c5ad1fadf99	0645fe54-ce1a-4ed5-b54c-727c2abf3814	11	1	0.049	339dee6f-1d8f-482c-8465-a87d2650af5e
29b1a15b-7025-4c1d-a16a-0cf674b2cb64	0645fe54-ce1a-4ed5-b54c-727c2abf3814	11	2	0.078	339dee6f-1d8f-482c-8465-a87d2650af5e
b2ba481c-220e-4cea-a095-37d68ea064d7	0645fe54-ce1a-4ed5-b54c-727c2abf3814	11	3	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
8d1e9e60-c842-4c1b-991f-b84621334e0f	0645fe54-ce1a-4ed5-b54c-727c2abf3814	11	4	0.194	339dee6f-1d8f-482c-8465-a87d2650af5e
22d9a53c-7739-425c-a91d-f7d956443463	0645fe54-ce1a-4ed5-b54c-727c2abf3814	11	5	0.049	339dee6f-1d8f-482c-8465-a87d2650af5e
ed54c8ae-362f-4c68-a6ea-96aee58c7db6	0645fe54-ce1a-4ed5-b54c-727c2abf3814	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
68d160a4-79ed-4961-84cd-b4ad3e25f5b5	0645fe54-ce1a-4ed5-b54c-727c2abf3814	12	2	0.125	339dee6f-1d8f-482c-8465-a87d2650af5e
af6607e4-ac54-43bc-bfb0-5b419767bff3	0645fe54-ce1a-4ed5-b54c-727c2abf3814	12	3	0.999	339dee6f-1d8f-482c-8465-a87d2650af5e
514ae771-911b-4996-9ea2-9160ae5b9b53	0645fe54-ce1a-4ed5-b54c-727c2abf3814	12	4	1.249	339dee6f-1d8f-482c-8465-a87d2650af5e
de548da8-374b-415c-8bf7-004bd6788c98	0645fe54-ce1a-4ed5-b54c-727c2abf3814	12	5	0.062	339dee6f-1d8f-482c-8465-a87d2650af5e
ea039050-78a6-4cb2-87b9-015913a76df2	0645fe54-ce1a-4ed5-b54c-727c2abf3814	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
522cdc37-f2d7-4ccc-a98c-d5aadfdf18c3	0645fe54-ce1a-4ed5-b54c-727c2abf3814	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2fa32ab2-c29e-4270-aa9e-d12452372073	0645fe54-ce1a-4ed5-b54c-727c2abf3814	13	3	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
e304f121-8ba7-48af-831a-aacc309b8238	0645fe54-ce1a-4ed5-b54c-727c2abf3814	13	4	0.360	339dee6f-1d8f-482c-8465-a87d2650af5e
0e18461f-b754-4439-9364-4299c92c9921	0645fe54-ce1a-4ed5-b54c-727c2abf3814	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fcc6b5ff-20dd-4131-8d1e-869ef74162a3	0645fe54-ce1a-4ed5-b54c-727c2abf3814	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cec2a89-de21-4faf-a170-1051201c0b4b	0645fe54-ce1a-4ed5-b54c-727c2abf3814	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c7c553dd-1e3d-40fb-934e-c97ee20bd651	0645fe54-ce1a-4ed5-b54c-727c2abf3814	14	3	0.037	339dee6f-1d8f-482c-8465-a87d2650af5e
fe6c8bd6-8cee-4da3-ab3c-2376254ac2f2	0645fe54-ce1a-4ed5-b54c-727c2abf3814	14	4	0.037	339dee6f-1d8f-482c-8465-a87d2650af5e
a98929cb-7ef5-4003-bce8-339682c62b21	0645fe54-ce1a-4ed5-b54c-727c2abf3814	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2d363fd7-fcc1-4829-9298-007d5634a139	0645fe54-ce1a-4ed5-b54c-727c2abf3814	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
11c2bc47-2959-42da-9c50-c260a6a1e818	0645fe54-ce1a-4ed5-b54c-727c2abf3814	15	2	0.075	339dee6f-1d8f-482c-8465-a87d2650af5e
643b1575-834d-4794-bd20-97d6ee11c3eb	0645fe54-ce1a-4ed5-b54c-727c2abf3814	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dcbfd759-d02d-4b26-b05c-2d5d1cdcf9c2	0645fe54-ce1a-4ed5-b54c-727c2abf3814	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
86cb6c5f-6712-4e78-8d2f-d9a6680796b6	0645fe54-ce1a-4ed5-b54c-727c2abf3814	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d6d167da-7b82-4226-a763-8b4dadd1db62	0645fe54-ce1a-4ed5-b54c-727c2abf3814	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
49042101-1eb6-4193-b39e-5a66237d2b63	0645fe54-ce1a-4ed5-b54c-727c2abf3814	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9da114fd-ff8c-4d40-9c80-b1cfd8018dba	0645fe54-ce1a-4ed5-b54c-727c2abf3814	16	3	0.075	339dee6f-1d8f-482c-8465-a87d2650af5e
ab7ab12b-3013-4cd2-845c-865127ae8971	0645fe54-ce1a-4ed5-b54c-727c2abf3814	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4fa469ae-f1e8-4dcc-9e07-2c4972790d4b	0645fe54-ce1a-4ed5-b54c-727c2abf3814	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
11120d65-6e0c-4c13-8d7a-d491d3cdcd0f	0645fe54-ce1a-4ed5-b54c-727c2abf3814	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
63fc3d06-00ca-4d30-ade4-67cce6e22057	0645fe54-ce1a-4ed5-b54c-727c2abf3814	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8c6bc735-ce4d-49a7-8df1-c435a7da73e6	0645fe54-ce1a-4ed5-b54c-727c2abf3814	17	3	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
9033cd45-25f2-41c0-b49e-724267613f9d	0645fe54-ce1a-4ed5-b54c-727c2abf3814	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c37beba6-a7ea-4622-adaa-181a1e9383bd	0645fe54-ce1a-4ed5-b54c-727c2abf3814	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8afa966f-0f02-4658-8787-ace5ef7ea655	0645fe54-ce1a-4ed5-b54c-727c2abf3814	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
17d75f37-f2d5-4f3a-b915-d76caec9f205	0645fe54-ce1a-4ed5-b54c-727c2abf3814	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
69b4fb78-6f04-48f9-a003-4ce09bb269b0	0645fe54-ce1a-4ed5-b54c-727c2abf3814	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
61096ce5-e37f-4eed-98a8-7c226e642304	0645fe54-ce1a-4ed5-b54c-727c2abf3814	18	4	0.075	339dee6f-1d8f-482c-8465-a87d2650af5e
ff71c4d2-7ff9-4a0d-ab9e-721e34a7fbf4	0645fe54-ce1a-4ed5-b54c-727c2abf3814	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5fbdfc6a-3b61-4a14-bd02-0a6f77bf949a	fd6ac260-c2a9-468d-9371-e8715ece7666	1	1	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
f91d97cb-f175-4c6f-b02c-3b0d1612cd8c	fd6ac260-c2a9-468d-9371-e8715ece7666	1	2	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
23be0670-ea6b-419d-ba39-9e8125dc3c6e	fd6ac260-c2a9-468d-9371-e8715ece7666	1	3	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
e18710ba-201d-4d70-869a-ed440f9cd1c3	fd6ac260-c2a9-468d-9371-e8715ece7666	1	4	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
a1c0c739-0fd3-47b4-95fd-b5f824fe88a5	fd6ac260-c2a9-468d-9371-e8715ece7666	1	5	0.033	339dee6f-1d8f-482c-8465-a87d2650af5e
30dc0750-2c6c-4993-a14b-67a4723b1730	fd6ac260-c2a9-468d-9371-e8715ece7666	2	1	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
dc7d7b7d-f3d0-4037-a0f8-7fcb3a0ac0a4	fd6ac260-c2a9-468d-9371-e8715ece7666	2	2	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
af092327-360d-4b9a-b25b-dc568001b386	fd6ac260-c2a9-468d-9371-e8715ece7666	2	3	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
4117fe12-d061-4478-83c7-2eb08df428ac	fd6ac260-c2a9-468d-9371-e8715ece7666	2	4	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
257e38cb-e36b-495c-b8c4-cba9c3e6064e	fd6ac260-c2a9-468d-9371-e8715ece7666	2	5	0.033	339dee6f-1d8f-482c-8465-a87d2650af5e
c0541787-ae32-4047-994a-eba4a782a30b	fd6ac260-c2a9-468d-9371-e8715ece7666	3	1	0.050	339dee6f-1d8f-482c-8465-a87d2650af5e
6369fc3d-230d-4343-8d70-98540baa4dff	fd6ac260-c2a9-468d-9371-e8715ece7666	3	2	0.060	339dee6f-1d8f-482c-8465-a87d2650af5e
79c5e77a-9c59-4474-879c-37064839c4da	fd6ac260-c2a9-468d-9371-e8715ece7666	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f822f4b1-1fbd-4ac6-8ced-e343da182790	fd6ac260-c2a9-468d-9371-e8715ece7666	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9a7ee3f6-60b8-45b8-a5c6-aff55d9f32f0	fd6ac260-c2a9-468d-9371-e8715ece7666	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
02fd4597-75d8-41b5-82f1-39a0d49ce30b	fd6ac260-c2a9-468d-9371-e8715ece7666	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
254aa3c2-205c-49a8-9a65-a38f4bd8b92a	fd6ac260-c2a9-468d-9371-e8715ece7666	4	2	0.067	339dee6f-1d8f-482c-8465-a87d2650af5e
42701b5b-ed74-4662-8313-7bc382fea757	fd6ac260-c2a9-468d-9371-e8715ece7666	4	3	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
43f0c92d-c62f-41e5-8888-0f505b52de70	fd6ac260-c2a9-468d-9371-e8715ece7666	4	4	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
d80f516d-c0ea-40d8-9127-fc4697b3a9af	fd6ac260-c2a9-468d-9371-e8715ece7666	4	5	0.033	339dee6f-1d8f-482c-8465-a87d2650af5e
c0c04bdf-d7a7-4ff1-b858-f3a58944ecc4	fd6ac260-c2a9-468d-9371-e8715ece7666	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e8c78b85-0958-4424-a877-fa0aa3cd64c3	fd6ac260-c2a9-468d-9371-e8715ece7666	5	2	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
3cdfaba7-a555-4a38-aae6-a29cee5f3270	fd6ac260-c2a9-468d-9371-e8715ece7666	5	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
d8601ab2-f4ae-4542-8dc6-ec56397085bf	fd6ac260-c2a9-468d-9371-e8715ece7666	5	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
19169d27-32fe-44e8-90d9-6e741d92cfd6	fd6ac260-c2a9-468d-9371-e8715ece7666	5	5	0.050	339dee6f-1d8f-482c-8465-a87d2650af5e
cde6949f-a75c-4e60-967c-7441799f550c	fd6ac260-c2a9-468d-9371-e8715ece7666	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
df638a08-77ff-476d-a7fc-38423c7d93b1	fd6ac260-c2a9-468d-9371-e8715ece7666	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f1de38c8-fca5-4c37-a9a3-22892cdaf7fe	fd6ac260-c2a9-468d-9371-e8715ece7666	6	3	0.325	339dee6f-1d8f-482c-8465-a87d2650af5e
13d4f6b6-961a-49ae-8ba0-955c172df55f	fd6ac260-c2a9-468d-9371-e8715ece7666	6	4	0.749	339dee6f-1d8f-482c-8465-a87d2650af5e
a2d09cf9-c187-431d-8417-8fd746dcfef4	fd6ac260-c2a9-468d-9371-e8715ece7666	6	5	0.050	339dee6f-1d8f-482c-8465-a87d2650af5e
49f7bd9e-49a4-41f5-bac8-ba35f43a5d88	fd6ac260-c2a9-468d-9371-e8715ece7666	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5d943e85-7ff0-462d-9157-ebc270f5fc4a	fd6ac260-c2a9-468d-9371-e8715ece7666	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0a6481f1-d5eb-4dff-a039-f8dfe76c46ef	fd6ac260-c2a9-468d-9371-e8715ece7666	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3827a98a-0f9d-44f8-8288-9e595038203d	fd6ac260-c2a9-468d-9371-e8715ece7666	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8aaa09fe-2e98-49ad-9f8f-8b284c2f09aa	fd6ac260-c2a9-468d-9371-e8715ece7666	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c9e07107-4f4b-4999-a9b1-39cfadd37888	fd6ac260-c2a9-468d-9371-e8715ece7666	8	1	0.175	339dee6f-1d8f-482c-8465-a87d2650af5e
78691427-85da-449c-aadd-2e992cd27883	fd6ac260-c2a9-468d-9371-e8715ece7666	8	2	0.499	339dee6f-1d8f-482c-8465-a87d2650af5e
adfba5e6-a837-4295-a081-125d0f0dec31	fd6ac260-c2a9-468d-9371-e8715ece7666	8	3	0.499	339dee6f-1d8f-482c-8465-a87d2650af5e
50de49cd-2835-459a-a7f8-0a1fa8dae913	fd6ac260-c2a9-468d-9371-e8715ece7666	8	4	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
ab0bff95-97bc-4771-a9c7-99bce314a15b	fd6ac260-c2a9-468d-9371-e8715ece7666	8	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
507e4820-c14b-48a2-aa58-0dec9edd3620	fd6ac260-c2a9-468d-9371-e8715ece7666	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5343229d-31f2-4dc8-95c0-c50fbd95f63f	fd6ac260-c2a9-468d-9371-e8715ece7666	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
93f1ad36-dad4-4078-85ac-ff3e5e4f9052	fd6ac260-c2a9-468d-9371-e8715ece7666	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
711c7d79-58eb-4e07-8063-84f8925c92a9	fd6ac260-c2a9-468d-9371-e8715ece7666	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cb31627f-4a04-4918-ad15-1a209015d360	fd6ac260-c2a9-468d-9371-e8715ece7666	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
789d0f12-9470-40e5-af05-d8b01b9bc5b4	fd6ac260-c2a9-468d-9371-e8715ece7666	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
873cecfa-a92d-4f00-b471-4c26523ff815	fd6ac260-c2a9-468d-9371-e8715ece7666	10	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
519241d8-d762-4892-a701-990220fba329	fd6ac260-c2a9-468d-9371-e8715ece7666	10	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
893a91d2-25b8-4e65-955a-e24b7fb42328	fd6ac260-c2a9-468d-9371-e8715ece7666	10	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b0e45e1a-0641-49a1-b4e6-9390de1ff849	fd6ac260-c2a9-468d-9371-e8715ece7666	10	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
41307ab6-591d-49d4-9805-7749b1b3d959	fd6ac260-c2a9-468d-9371-e8715ece7666	11	1	0.033	339dee6f-1d8f-482c-8465-a87d2650af5e
58464ab8-e387-41d5-91fd-36f300fa144b	fd6ac260-c2a9-468d-9371-e8715ece7666	11	2	0.053	339dee6f-1d8f-482c-8465-a87d2650af5e
c444a814-2f26-485c-977e-8224c63f4c6b	fd6ac260-c2a9-468d-9371-e8715ece7666	11	3	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
8e637ed9-d0d2-40ee-99f2-a6f5b5b945a8	fd6ac260-c2a9-468d-9371-e8715ece7666	11	4	0.133	339dee6f-1d8f-482c-8465-a87d2650af5e
bb462ab8-2aff-4fe5-898d-f43e6764e988	fd6ac260-c2a9-468d-9371-e8715ece7666	11	5	0.033	339dee6f-1d8f-482c-8465-a87d2650af5e
6f051c92-2afd-425e-98a2-15caa06047df	fd6ac260-c2a9-468d-9371-e8715ece7666	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
11cf2e40-5cc9-482a-985e-fa3ca91f34be	fd6ac260-c2a9-468d-9371-e8715ece7666	12	2	0.125	339dee6f-1d8f-482c-8465-a87d2650af5e
9ba50dee-4781-48e2-a4ae-7660b181e24d	fd6ac260-c2a9-468d-9371-e8715ece7666	12	3	0.999	339dee6f-1d8f-482c-8465-a87d2650af5e
ed5d44a2-4b47-4a15-94a9-80cc883c607b	fd6ac260-c2a9-468d-9371-e8715ece7666	12	4	1.249	339dee6f-1d8f-482c-8465-a87d2650af5e
d9e44040-5494-4710-978c-fd690d8dddf5	fd6ac260-c2a9-468d-9371-e8715ece7666	12	5	0.062	339dee6f-1d8f-482c-8465-a87d2650af5e
9a27854f-f982-4694-aefd-32edf049a9d0	fd6ac260-c2a9-468d-9371-e8715ece7666	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ffe43c12-fcc6-4217-9017-a9b97b6b8b22	fd6ac260-c2a9-468d-9371-e8715ece7666	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a5e635d3-1074-4fde-9d75-39f5ea47b9e5	fd6ac260-c2a9-468d-9371-e8715ece7666	13	3	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
aab1fe2e-dbf2-4820-9c99-047220d8ab29	fd6ac260-c2a9-468d-9371-e8715ece7666	13	4	0.360	339dee6f-1d8f-482c-8465-a87d2650af5e
0df4e085-f066-4cd0-aaae-64c19a3ac61a	fd6ac260-c2a9-468d-9371-e8715ece7666	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0e5a9e30-fbad-43fc-8549-ff7432ece061	fd6ac260-c2a9-468d-9371-e8715ece7666	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9a5b94d6-fc01-46b1-9bd7-2784e5a1426b	fd6ac260-c2a9-468d-9371-e8715ece7666	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
455d1bc4-fca9-4a9b-848f-af8043ae1874	fd6ac260-c2a9-468d-9371-e8715ece7666	14	3	0.037	339dee6f-1d8f-482c-8465-a87d2650af5e
761cd310-2ff2-439c-83b5-f701b83300e3	fd6ac260-c2a9-468d-9371-e8715ece7666	14	4	0.037	339dee6f-1d8f-482c-8465-a87d2650af5e
c9aa403b-c5b7-4b14-aeee-75e879f1f7aa	fd6ac260-c2a9-468d-9371-e8715ece7666	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
39e839be-2b5e-436c-b02e-2b32bec865fc	fd6ac260-c2a9-468d-9371-e8715ece7666	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
28dc1ac7-29b3-4d2d-8a45-026e6f9985d1	fd6ac260-c2a9-468d-9371-e8715ece7666	15	2	0.075	339dee6f-1d8f-482c-8465-a87d2650af5e
db743ff4-6f15-430d-ab92-83cb6c61e015	fd6ac260-c2a9-468d-9371-e8715ece7666	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7afae4ce-8e1d-479a-aa62-44cb70999f82	fd6ac260-c2a9-468d-9371-e8715ece7666	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
04759bc8-8092-4897-a965-0834ccb32b95	fd6ac260-c2a9-468d-9371-e8715ece7666	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
43e67571-4713-447d-832e-d3ae89d7115a	fd6ac260-c2a9-468d-9371-e8715ece7666	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dd34ca32-330c-4001-9dbe-1b9d926638f0	fd6ac260-c2a9-468d-9371-e8715ece7666	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
778e1cc1-965a-484c-9ed6-b2c1dd5792bc	fd6ac260-c2a9-468d-9371-e8715ece7666	16	3	0.075	339dee6f-1d8f-482c-8465-a87d2650af5e
7917af5d-0858-4cf1-b561-8ac72cd5ba1b	fd6ac260-c2a9-468d-9371-e8715ece7666	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
18ab89a2-156b-4d07-8837-9807e878d024	fd6ac260-c2a9-468d-9371-e8715ece7666	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4ab7849f-cea3-4203-b0ab-c127d6c700df	fd6ac260-c2a9-468d-9371-e8715ece7666	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
73328cf3-817e-46a4-a7dc-52a0e362e3b9	fd6ac260-c2a9-468d-9371-e8715ece7666	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
357d0ff5-996c-4e36-9292-f7d787022bdf	fd6ac260-c2a9-468d-9371-e8715ece7666	17	3	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
2e99882a-d560-4436-96b8-94035fbcf84b	fd6ac260-c2a9-468d-9371-e8715ece7666	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a70fd2c6-77a6-4588-b368-497a156d060d	fd6ac260-c2a9-468d-9371-e8715ece7666	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
49ad73d7-3e09-46a4-a9cd-4abf34ef2db0	fd6ac260-c2a9-468d-9371-e8715ece7666	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
0f1b9ab7-0818-4634-94f0-bf00539c266c	fd6ac260-c2a9-468d-9371-e8715ece7666	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7793c924-48d1-4087-b16b-2bd6922ce1dc	fd6ac260-c2a9-468d-9371-e8715ece7666	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d73d0170-183c-4152-9b04-9ff5de2fc6f4	fd6ac260-c2a9-468d-9371-e8715ece7666	18	4	0.075	339dee6f-1d8f-482c-8465-a87d2650af5e
26af2d05-dda1-43ef-b1c7-4f015e6d7b6b	fd6ac260-c2a9-468d-9371-e8715ece7666	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ca3b5685-0b83-45a1-9d39-82906872247b	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	1	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7f022e08-fa90-4f00-be25-8a6c39b8a14e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9ee356f0-7275-48b1-9d81-86ed4ad8cac3	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fdde75c8-8b6b-4f24-b7ea-f7c22906fe9e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
72842864-f005-4e8e-99cc-ecfb0822c795	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
2e57ddce-9703-4813-b8cd-1aa6bcb4c9d6	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	1	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6704846d-87bc-4221-8506-f278856e1f11	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	2	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
59b63e27-3f1e-4cbd-89b0-50609e0f8dca	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
09610ec6-51de-40f2-aadb-65af006a3a33	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b39aee48-5eed-48d3-ad7b-6bb3a3ab85ce	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
450ba91f-2878-493a-a40e-eb65410d37d7	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	1	0.776	339dee6f-1d8f-482c-8465-a87d2650af5e
4512fc2e-c784-4fd4-b937-f8d4fef36da2	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	2	0.931	339dee6f-1d8f-482c-8465-a87d2650af5e
5c2e1d74-6c16-466e-9d45-9c2797de1294	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	3	0.931	339dee6f-1d8f-482c-8465-a87d2650af5e
373cdd53-6245-4216-a583-c032a9c878d9	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ba490f7d-82af-4608-a631-b2a37bc4bd6f	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a97cc201-d9c9-4044-b0f8-03d52e9e0e08	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fee5a2e9-4282-40e7-a81b-146fd07807f0	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	2	0.500	339dee6f-1d8f-482c-8465-a87d2650af5e
f92b0882-b2fa-49ca-845d-0710a71888ec	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a936ca93-9dbb-44ff-8018-fd0c0b3322fe	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e815061b-2016-4d64-9918-3756518408dd	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
972e3272-63ec-4e9a-b0b0-59219465acad	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ad1475e5-ba96-458d-a4b4-3d9357fc1f07	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	2	1.500	339dee6f-1d8f-482c-8465-a87d2650af5e
0d369726-e73a-4e7c-823a-7bfbffeba8b4	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	3	3.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e8bd15d8-8507-40fc-99a2-d03119dabcf9	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	4	3.000	339dee6f-1d8f-482c-8465-a87d2650af5e
381c6a22-6608-4024-881b-4fab8e0c8b0a	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	5	0.750	339dee6f-1d8f-482c-8465-a87d2650af5e
8a86baa6-c447-4655-8b60-2897a54a88fe	5d1abc42-9e14-47f5-92e8-a3bf03b96072	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9e10746f-a21a-45e4-8c0c-4f2ff0975571	5d1abc42-9e14-47f5-92e8-a3bf03b96072	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
df7a11f2-0951-404b-a887-a93a2bf9b250	5d1abc42-9e14-47f5-92e8-a3bf03b96072	6	3	10.867	339dee6f-1d8f-482c-8465-a87d2650af5e
fa8b6c58-5369-4e6e-8b1d-246e5b39da5e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	6	4	16.766	339dee6f-1d8f-482c-8465-a87d2650af5e
11903493-66c9-46d6-b151-8f4c1c24f8bb	5d1abc42-9e14-47f5-92e8-a3bf03b96072	6	5	3.105	339dee6f-1d8f-482c-8465-a87d2650af5e
e299c3c5-23ab-4fbb-bfed-071c8404134e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	7	1	4.347	339dee6f-1d8f-482c-8465-a87d2650af5e
a4828c15-9a41-4fd8-943d-dfc09077eaaf	5d1abc42-9e14-47f5-92e8-a3bf03b96072	7	2	9.314	339dee6f-1d8f-482c-8465-a87d2650af5e
665e732b-70b8-45d9-b1da-f177587d6b47	5d1abc42-9e14-47f5-92e8-a3bf03b96072	7	3	9.314	339dee6f-1d8f-482c-8465-a87d2650af5e
0c39e34c-03ab-466e-a79a-20c96eeb714d	5d1abc42-9e14-47f5-92e8-a3bf03b96072	7	4	4.657	339dee6f-1d8f-482c-8465-a87d2650af5e
2f777eca-cd37-4cae-a3f2-964b12f35c3e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	7	5	3.105	339dee6f-1d8f-482c-8465-a87d2650af5e
877af75a-d9ef-4596-b5df-0429515122dc	5d1abc42-9e14-47f5-92e8-a3bf03b96072	8	1	4.347	339dee6f-1d8f-482c-8465-a87d2650af5e
c6f168bb-c491-41d8-9363-86e5caa06561	5d1abc42-9e14-47f5-92e8-a3bf03b96072	8	2	9.314	339dee6f-1d8f-482c-8465-a87d2650af5e
9ec758bb-70c6-4ed5-a0e4-dc9c5a9b1eb8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	8	3	9.314	339dee6f-1d8f-482c-8465-a87d2650af5e
b654458e-d47c-4025-b14d-110a2e53f22d	5d1abc42-9e14-47f5-92e8-a3bf03b96072	8	4	4.657	339dee6f-1d8f-482c-8465-a87d2650af5e
7d004223-258a-4ea9-9f85-ac7efe9247d6	5d1abc42-9e14-47f5-92e8-a3bf03b96072	8	5	3.105	339dee6f-1d8f-482c-8465-a87d2650af5e
11b8cab3-06ca-4d1b-9a55-8657594ee5c8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
716904e4-8fdd-4a6a-9bd7-e203f7d4ac7b	5d1abc42-9e14-47f5-92e8-a3bf03b96072	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
35944541-2e54-401c-9f30-ba33606033e1	5d1abc42-9e14-47f5-92e8-a3bf03b96072	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af29a551-c71d-4798-a63c-39db761f3987	5d1abc42-9e14-47f5-92e8-a3bf03b96072	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af400b30-570c-4e5b-a872-d7b242a02336	5d1abc42-9e14-47f5-92e8-a3bf03b96072	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
67116769-d15e-4f02-ad0d-71a136cda9ee	5d1abc42-9e14-47f5-92e8-a3bf03b96072	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
954f95f9-0666-49b0-afa4-28d087e2bb11	5d1abc42-9e14-47f5-92e8-a3bf03b96072	10	2	1.552	339dee6f-1d8f-482c-8465-a87d2650af5e
37108ae0-2a4e-465c-b73b-7e26606268f9	5d1abc42-9e14-47f5-92e8-a3bf03b96072	10	3	1.552	339dee6f-1d8f-482c-8465-a87d2650af5e
b185e9ef-a115-4aef-a02e-e0ff0928473d	5d1abc42-9e14-47f5-92e8-a3bf03b96072	10	4	1.552	339dee6f-1d8f-482c-8465-a87d2650af5e
0471d9bb-a967-4d08-ab6a-5a0f5ac1e63b	5d1abc42-9e14-47f5-92e8-a3bf03b96072	10	5	1.552	339dee6f-1d8f-482c-8465-a87d2650af5e
15782e40-e3ae-449d-b448-d3ce4e3d63b6	5d1abc42-9e14-47f5-92e8-a3bf03b96072	11	1	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
b9e644c6-1538-4ce1-b474-44c5914b76ea	5d1abc42-9e14-47f5-92e8-a3bf03b96072	11	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
ec3b2b03-a8fa-4cdd-8931-3de26901f7b8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	11	3	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cc9c4ea7-0792-4619-a1c8-19ea71ebbbee	5d1abc42-9e14-47f5-92e8-a3bf03b96072	11	4	1.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bde2099c-672f-492d-848a-7aa7ac585946	5d1abc42-9e14-47f5-92e8-a3bf03b96072	11	5	0.250	339dee6f-1d8f-482c-8465-a87d2650af5e
7d55306d-4bfe-4fb7-b7e7-2cfa8746b9aa	5d1abc42-9e14-47f5-92e8-a3bf03b96072	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
31a065b2-5a49-43d7-bebf-47106bbad916	5d1abc42-9e14-47f5-92e8-a3bf03b96072	12	2	1.940	339dee6f-1d8f-482c-8465-a87d2650af5e
2c65b8db-8479-425a-9d3c-63a07dac0c96	5d1abc42-9e14-47f5-92e8-a3bf03b96072	12	3	15.524	339dee6f-1d8f-482c-8465-a87d2650af5e
b328dc82-06ff-470a-b1ba-d2f0d9a0fe1b	5d1abc42-9e14-47f5-92e8-a3bf03b96072	12	4	19.405	339dee6f-1d8f-482c-8465-a87d2650af5e
7419118e-4f6f-4435-ada2-d086f167b1c8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	12	5	0.970	339dee6f-1d8f-482c-8465-a87d2650af5e
1cc06f10-03bc-4a19-8ee8-651f6ea17a62	5d1abc42-9e14-47f5-92e8-a3bf03b96072	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b7f1d7d5-a7ce-453b-a614-2a6b6a366baa	5d1abc42-9e14-47f5-92e8-a3bf03b96072	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
18c1cbdc-a66e-4fe8-9193-c9c9f619d02a	5d1abc42-9e14-47f5-92e8-a3bf03b96072	13	3	6.986	339dee6f-1d8f-482c-8465-a87d2650af5e
8abec9ba-d0d0-4661-a2f2-3a62fd3cad0c	5d1abc42-9e14-47f5-92e8-a3bf03b96072	13	4	6.986	339dee6f-1d8f-482c-8465-a87d2650af5e
46d50df8-fbb0-4352-9817-745e4005351b	5d1abc42-9e14-47f5-92e8-a3bf03b96072	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
cb11d2a5-22e1-4dbc-a9cc-bee043535a0a	5d1abc42-9e14-47f5-92e8-a3bf03b96072	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
61faa491-697c-4c38-9ccf-6952537d00d3	5d1abc42-9e14-47f5-92e8-a3bf03b96072	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7aa04b08-6a34-49c5-ace2-01e2a408145e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	14	3	0.582	339dee6f-1d8f-482c-8465-a87d2650af5e
3692fca5-6589-42f3-859a-f41f5fa56994	5d1abc42-9e14-47f5-92e8-a3bf03b96072	14	4	0.582	339dee6f-1d8f-482c-8465-a87d2650af5e
87c1c381-3997-4fff-bb81-908d3071c022	5d1abc42-9e14-47f5-92e8-a3bf03b96072	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6680a38-53fd-43cc-bb06-d35e24c47d35	5d1abc42-9e14-47f5-92e8-a3bf03b96072	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9c1c2a51-6a3c-47b2-8cd5-7353acb002ef	5d1abc42-9e14-47f5-92e8-a3bf03b96072	15	2	1.164	339dee6f-1d8f-482c-8465-a87d2650af5e
eb6cfa69-c9e9-499d-818d-6c683fd1cda3	5d1abc42-9e14-47f5-92e8-a3bf03b96072	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
2cfb200c-34f9-4ab1-b8c6-26ef46b30aa6	5d1abc42-9e14-47f5-92e8-a3bf03b96072	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
59e3a710-d318-416b-adf5-590be0716cd5	5d1abc42-9e14-47f5-92e8-a3bf03b96072	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a708755a-ea09-4895-a949-29a7d3b189c8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
08f1ae51-5185-4707-bac7-d98e76855c93	5d1abc42-9e14-47f5-92e8-a3bf03b96072	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b6259f0f-2871-40cc-9f6a-1b4f4c246438	5d1abc42-9e14-47f5-92e8-a3bf03b96072	16	3	1.164	339dee6f-1d8f-482c-8465-a87d2650af5e
f25122ec-a980-4224-a634-831ee5aacda8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a932b09d-2d9f-4346-abf2-12ab63c35cc8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7bcf83f7-f137-424b-aab4-1ab0d109fb84	5d1abc42-9e14-47f5-92e8-a3bf03b96072	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3a95e28a-28eb-41b4-b6d3-49df77ffd414	5d1abc42-9e14-47f5-92e8-a3bf03b96072	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7d86a7ce-fc88-4603-8cc8-dd697555ce7e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	17	3	1.552	339dee6f-1d8f-482c-8465-a87d2650af5e
0beda394-c5f7-46e1-8e4d-3ad46601e46c	5d1abc42-9e14-47f5-92e8-a3bf03b96072	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5418c432-006e-4067-abb6-69294f2a1288	5d1abc42-9e14-47f5-92e8-a3bf03b96072	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
54fe7714-89da-4e26-a2ac-7d3efa2a59b4	5d1abc42-9e14-47f5-92e8-a3bf03b96072	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e0b18c44-0cd2-4bb0-a369-f0468e69b30b	5d1abc42-9e14-47f5-92e8-a3bf03b96072	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c1685058-8340-4835-9468-6b8ecadc30a7	5d1abc42-9e14-47f5-92e8-a3bf03b96072	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7cb49903-bfd0-4c7d-92ce-a3f24a881fe8	5d1abc42-9e14-47f5-92e8-a3bf03b96072	18	4	1.164	339dee6f-1d8f-482c-8465-a87d2650af5e
7c02bbeb-e221-4c02-8b48-09f9b225dc04	5d1abc42-9e14-47f5-92e8-a3bf03b96072	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
79b62d60-ab84-4513-a3b9-9626564e23dd	5484af78-8853-475b-95c4-e6d48106a41e	1	1	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
3b792ebb-942d-47df-b768-6fa5eb872c86	5484af78-8853-475b-95c4-e6d48106a41e	1	2	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
377dfe2f-e754-4512-9d9d-6be908b8bc11	5484af78-8853-475b-95c4-e6d48106a41e	1	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
505f02c7-e5ae-48ea-b449-15c5ed43fde8	5484af78-8853-475b-95c4-e6d48106a41e	1	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
4663f900-bcc6-4606-af0e-bd4d2edfd20a	5484af78-8853-475b-95c4-e6d48106a41e	1	5	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
fbda1be4-0a68-4223-9f43-573837ec99c5	5484af78-8853-475b-95c4-e6d48106a41e	2	1	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
aae292c1-e732-41a0-9aac-d79f2f892ffc	5484af78-8853-475b-95c4-e6d48106a41e	2	2	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
9d16d782-8e77-4f46-879e-8ef2bc965d1b	5484af78-8853-475b-95c4-e6d48106a41e	2	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
8fe85bff-435b-4d0e-b9d6-34239f4a9406	5484af78-8853-475b-95c4-e6d48106a41e	2	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
d7378f28-c833-4ab1-997a-8cafa09cb16a	5484af78-8853-475b-95c4-e6d48106a41e	2	5	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
e7a90ce0-c30c-4b79-ade7-2279cb96a127	5484af78-8853-475b-95c4-e6d48106a41e	3	1	0.211	339dee6f-1d8f-482c-8465-a87d2650af5e
95b4b3a0-0a8b-45ba-828b-04bd8a93a540	5484af78-8853-475b-95c4-e6d48106a41e	3	2	0.253	339dee6f-1d8f-482c-8465-a87d2650af5e
bd495d2f-1585-4b04-8480-6be92850b1e4	5484af78-8853-475b-95c4-e6d48106a41e	3	3	0.253	339dee6f-1d8f-482c-8465-a87d2650af5e
e7ce56a3-ed41-4f8f-a1b9-3c4d9cde5fa9	5484af78-8853-475b-95c4-e6d48106a41e	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d295b14e-3da5-46ed-a645-2826ede4acdd	5484af78-8853-475b-95c4-e6d48106a41e	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a13f5d49-d6f1-43f9-b76b-3bd47d6c4076	5484af78-8853-475b-95c4-e6d48106a41e	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6bb00606-b5b6-4243-b7d4-ddf08c34c676	5484af78-8853-475b-95c4-e6d48106a41e	4	2	0.442	339dee6f-1d8f-482c-8465-a87d2650af5e
199d175b-1ac0-4ac1-81d7-8b5ae86e353d	5484af78-8853-475b-95c4-e6d48106a41e	4	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
0fd139f9-0bf4-4aa7-a557-c7ce4ee1cc35	5484af78-8853-475b-95c4-e6d48106a41e	4	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
748b4d7f-4a1e-43d7-9dff-aa247ea62ea1	5484af78-8853-475b-95c4-e6d48106a41e	4	5	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
4e9fbd41-e1c6-4885-be62-fc958e57a071	5484af78-8853-475b-95c4-e6d48106a41e	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c49b120e-b477-47bc-8176-205d3c6dbf4e	5484af78-8853-475b-95c4-e6d48106a41e	5	2	1.325	339dee6f-1d8f-482c-8465-a87d2650af5e
75e57495-e306-44d1-8693-bd72460266df	5484af78-8853-475b-95c4-e6d48106a41e	5	3	2.649	339dee6f-1d8f-482c-8465-a87d2650af5e
f021da3a-4f75-48b3-aa1e-4872e9e95591	5484af78-8853-475b-95c4-e6d48106a41e	5	4	2.649	339dee6f-1d8f-482c-8465-a87d2650af5e
50efb0b4-4e84-40e5-8a6c-ce5f968db92e	5484af78-8853-475b-95c4-e6d48106a41e	5	5	0.662	339dee6f-1d8f-482c-8465-a87d2650af5e
d6dff47b-be6d-4639-b503-5021311c29c1	5484af78-8853-475b-95c4-e6d48106a41e	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4665e702-ad00-4146-928b-e54b3e9f0952	5484af78-8853-475b-95c4-e6d48106a41e	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f37c4bf3-855c-438d-b454-9875c2103451	5484af78-8853-475b-95c4-e6d48106a41e	6	3	2.947	339dee6f-1d8f-482c-8465-a87d2650af5e
e05865a4-d642-4c5f-b07c-8b901e2285be	5484af78-8853-475b-95c4-e6d48106a41e	6	4	4.547	339dee6f-1d8f-482c-8465-a87d2650af5e
03ce39b8-2399-4d2e-99e7-2c1e2e935e86	5484af78-8853-475b-95c4-e6d48106a41e	6	5	0.842	339dee6f-1d8f-482c-8465-a87d2650af5e
d206db00-5769-43b8-b224-e55c71ac36e3	5484af78-8853-475b-95c4-e6d48106a41e	7	1	1.179	339dee6f-1d8f-482c-8465-a87d2650af5e
8e515839-f738-4370-859c-6e3f33e19ee2	5484af78-8853-475b-95c4-e6d48106a41e	7	2	2.526	339dee6f-1d8f-482c-8465-a87d2650af5e
75e8ba06-04f4-48ba-b409-fd94ba026dfc	5484af78-8853-475b-95c4-e6d48106a41e	7	3	2.526	339dee6f-1d8f-482c-8465-a87d2650af5e
3df1d4bb-ad46-4363-ad35-1ff58d26c052	5484af78-8853-475b-95c4-e6d48106a41e	7	4	1.263	339dee6f-1d8f-482c-8465-a87d2650af5e
9aa3ad55-4a87-4fb2-9ef9-fc2b51521034	5484af78-8853-475b-95c4-e6d48106a41e	7	5	0.842	339dee6f-1d8f-482c-8465-a87d2650af5e
1ee91cea-05dc-47a4-91d2-1c442cf8b092	5484af78-8853-475b-95c4-e6d48106a41e	8	1	1.179	339dee6f-1d8f-482c-8465-a87d2650af5e
f5fbe73d-09da-4e57-8dbe-24d8666c1341	5484af78-8853-475b-95c4-e6d48106a41e	8	2	2.526	339dee6f-1d8f-482c-8465-a87d2650af5e
8b4bbb09-60b1-4f54-b058-f6e47263b2f1	5484af78-8853-475b-95c4-e6d48106a41e	8	3	2.526	339dee6f-1d8f-482c-8465-a87d2650af5e
ffcd14c9-2a11-4421-b14c-e1d11317f07d	5484af78-8853-475b-95c4-e6d48106a41e	8	4	1.263	339dee6f-1d8f-482c-8465-a87d2650af5e
2232393a-36f1-4604-b061-a1d7c4ce66fa	5484af78-8853-475b-95c4-e6d48106a41e	8	5	0.842	339dee6f-1d8f-482c-8465-a87d2650af5e
76952339-c22e-4cf6-a66f-1c1f29026d9f	5484af78-8853-475b-95c4-e6d48106a41e	9	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
d66d8c5c-38d9-4f8f-8f8b-7d22ef911777	5484af78-8853-475b-95c4-e6d48106a41e	9	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
e6c1ca2c-2cfa-4938-b51d-1f4df74faf42	5484af78-8853-475b-95c4-e6d48106a41e	9	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
b86b77dd-72f3-44fd-affb-c5cf2cb3ca10	5484af78-8853-475b-95c4-e6d48106a41e	9	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
98335c4a-34ff-4305-910a-a051fd635160	5484af78-8853-475b-95c4-e6d48106a41e	9	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7d06d024-5a38-4e09-b021-9c469696d542	5484af78-8853-475b-95c4-e6d48106a41e	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8cc53bdf-e556-4b30-bb27-9caec3a14388	5484af78-8853-475b-95c4-e6d48106a41e	10	2	0.421	339dee6f-1d8f-482c-8465-a87d2650af5e
712684fe-4b1e-46f0-a20a-455ce17c0c97	5484af78-8853-475b-95c4-e6d48106a41e	10	3	0.421	339dee6f-1d8f-482c-8465-a87d2650af5e
16b5f389-5856-41f8-b601-b88034208af0	5484af78-8853-475b-95c4-e6d48106a41e	10	4	0.421	339dee6f-1d8f-482c-8465-a87d2650af5e
f1786575-6570-41f5-9702-2194ca6040d1	5484af78-8853-475b-95c4-e6d48106a41e	10	5	0.421	339dee6f-1d8f-482c-8465-a87d2650af5e
12652610-fec5-4b8e-8157-278f72d5aecc	5484af78-8853-475b-95c4-e6d48106a41e	11	1	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
89067249-9a51-47e0-90b6-5dfbcf567826	5484af78-8853-475b-95c4-e6d48106a41e	11	2	0.353	339dee6f-1d8f-482c-8465-a87d2650af5e
50dfdb18-b704-423b-a1f3-950d0dd57a6b	5484af78-8853-475b-95c4-e6d48106a41e	11	3	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
8c0a157e-5b90-415e-a02c-0324d8184fe6	5484af78-8853-475b-95c4-e6d48106a41e	11	4	0.883	339dee6f-1d8f-482c-8465-a87d2650af5e
9908c0b7-d09a-41fa-b31c-d539462b330e	5484af78-8853-475b-95c4-e6d48106a41e	11	5	0.221	339dee6f-1d8f-482c-8465-a87d2650af5e
2620468e-9392-4c29-938e-124ee967f5c1	5484af78-8853-475b-95c4-e6d48106a41e	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a3d71ef1-8da2-43ae-9f42-4470c1c31e9d	5484af78-8853-475b-95c4-e6d48106a41e	12	2	0.526	339dee6f-1d8f-482c-8465-a87d2650af5e
960102b3-06aa-4c6a-b42d-de6a3978e047	5484af78-8853-475b-95c4-e6d48106a41e	12	3	4.210	339dee6f-1d8f-482c-8465-a87d2650af5e
2b74d3a7-9ace-4239-a895-840254c22b90	5484af78-8853-475b-95c4-e6d48106a41e	12	4	5.263	339dee6f-1d8f-482c-8465-a87d2650af5e
22b68398-fdcb-4380-a5d3-6847f2e2947d	5484af78-8853-475b-95c4-e6d48106a41e	12	5	0.263	339dee6f-1d8f-482c-8465-a87d2650af5e
c0c40aa3-cc1e-4db3-bc7b-40d0a111254a	5484af78-8853-475b-95c4-e6d48106a41e	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c8cab270-3bb0-4167-8dc8-8caea5de6197	5484af78-8853-475b-95c4-e6d48106a41e	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1e434063-2a4a-4d9b-815a-ac4ef2924227	5484af78-8853-475b-95c4-e6d48106a41e	13	3	1.895	339dee6f-1d8f-482c-8465-a87d2650af5e
9494ee3d-a089-4da4-9f5f-5e81e5d44d44	5484af78-8853-475b-95c4-e6d48106a41e	13	4	1.895	339dee6f-1d8f-482c-8465-a87d2650af5e
9137e58e-6c84-4ce3-8749-cc7be227f39a	5484af78-8853-475b-95c4-e6d48106a41e	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
73e5f49c-1fdf-4127-b003-ae0fda16ccbf	5484af78-8853-475b-95c4-e6d48106a41e	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b1115d5-370f-405a-9c3b-59a91162e5a6	5484af78-8853-475b-95c4-e6d48106a41e	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
216eec7d-248e-46f2-94b2-a6123c857389	5484af78-8853-475b-95c4-e6d48106a41e	14	3	0.158	339dee6f-1d8f-482c-8465-a87d2650af5e
a2bb9d9f-ce38-4b92-9bb1-80e6513e9eff	5484af78-8853-475b-95c4-e6d48106a41e	14	4	0.158	339dee6f-1d8f-482c-8465-a87d2650af5e
821e56e2-fd66-4468-a96f-74151bae33b1	5484af78-8853-475b-95c4-e6d48106a41e	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3e81e2a5-0972-4cf1-a852-ae6c26b94d95	5484af78-8853-475b-95c4-e6d48106a41e	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dfa57f4f-37f9-4d25-bd28-f9ea5c33b3a0	5484af78-8853-475b-95c4-e6d48106a41e	15	2	0.316	339dee6f-1d8f-482c-8465-a87d2650af5e
d662e40e-946a-4cf7-acfb-5775c06fe7f2	5484af78-8853-475b-95c4-e6d48106a41e	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4a6d47e0-5a4b-4f8f-9d84-c6f7e32bce00	5484af78-8853-475b-95c4-e6d48106a41e	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bbcf9c7c-80d9-4f3e-8a3b-d2ac89bf277b	5484af78-8853-475b-95c4-e6d48106a41e	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6b3c7e14-5fdf-4697-aa4e-7e084b41758e	5484af78-8853-475b-95c4-e6d48106a41e	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
9db5d142-accb-4fa4-9d88-fde2e914e804	5484af78-8853-475b-95c4-e6d48106a41e	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4722b6c1-b3b6-4b22-abc5-21ae3ad5ca0d	5484af78-8853-475b-95c4-e6d48106a41e	16	3	0.316	339dee6f-1d8f-482c-8465-a87d2650af5e
6ec4f07e-31e7-4b61-8617-96f34c1dcb2c	5484af78-8853-475b-95c4-e6d48106a41e	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
554d08ab-1807-4853-ac3f-5d71eed916c5	5484af78-8853-475b-95c4-e6d48106a41e	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
496624aa-b0c0-4419-9af7-97f1c8f916ce	5484af78-8853-475b-95c4-e6d48106a41e	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
f9d295ac-4e93-4b57-8fc6-38568162d4a5	5484af78-8853-475b-95c4-e6d48106a41e	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8f9a1d6e-c73b-4ab3-bdc7-d06e120b611f	5484af78-8853-475b-95c4-e6d48106a41e	17	3	0.421	339dee6f-1d8f-482c-8465-a87d2650af5e
b733162c-9160-4fa4-9151-174132921bbc	5484af78-8853-475b-95c4-e6d48106a41e	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7d13388c-bb65-4f0a-a109-6ce454f63f7e	5484af78-8853-475b-95c4-e6d48106a41e	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c2f5d0ef-6c3e-4fb6-83ae-fca0a52a2520	5484af78-8853-475b-95c4-e6d48106a41e	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5bc2d34d-d8a8-41c8-b34c-b3f6ea2d8502	5484af78-8853-475b-95c4-e6d48106a41e	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a93635b6-6dcb-48e4-8458-2be6039f607b	5484af78-8853-475b-95c4-e6d48106a41e	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
3b37876e-d446-41b0-976e-39629f016c61	5484af78-8853-475b-95c4-e6d48106a41e	18	4	0.316	339dee6f-1d8f-482c-8465-a87d2650af5e
3d659808-0e77-4d81-914f-563d8c9fa45d	5484af78-8853-475b-95c4-e6d48106a41e	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4e5452b8-1ab5-4480-b7ef-beceeec8e45a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	1	1	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
dcb7d795-f0c9-4f70-992f-619a1d3d6d3f	66407147-8ee2-4b34-a7e7-45d38c9e35a8	1	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
d2caa327-bcd2-42fd-b03c-ecd348f4fac4	66407147-8ee2-4b34-a7e7-45d38c9e35a8	1	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
3f1e350a-c32b-4a04-b93f-d83e3a3e9cc5	66407147-8ee2-4b34-a7e7-45d38c9e35a8	1	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
ae47a343-a6ce-40e3-99dd-c07606dda35a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	1	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
9a0f072a-2440-4144-baf4-1e1905208b25	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	1	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
8731b93a-54f1-419f-a068-d7ae6e0c284d	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	2	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
07b7833e-15fe-4aa8-8c35-a235737b310f	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
f3a34894-1160-4341-aead-1a89795e84ed	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	4	0.300	339dee6f-1d8f-482c-8465-a87d2650af5e
3e705810-feef-4eb5-9cd0-765f422ce777	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
d54f3140-4c19-4445-82cd-dbc41c282f7c	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	1	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
4768871e-b5f3-4c07-bde2-4aa9e43cdd99	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	2	0.062	339dee6f-1d8f-482c-8465-a87d2650af5e
817d8f9f-6353-45e4-a43f-9f1b3797626a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
906b578d-3f19-41f0-a844-0397b7eafd88	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
8b719962-2bb3-4a7c-89f1-9d5ab4d3313c	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
dd9495de-5ed6-4df9-803a-82290cb71d48	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a2eb41c5-d09f-4768-8585-286bf93375bc	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	2	0.200	339dee6f-1d8f-482c-8465-a87d2650af5e
58324a5e-b96d-49cc-ae94-99e1604474b8	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
436c5607-29ac-483b-b878-26bed6d20357	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
97637645-13f2-48a6-a7a9-8f744ef99aa9	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
c199ff80-2fe4-48f4-955f-08dffaf00e63	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
7bd9dc5f-089d-402e-a6b7-148235b408e2	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	2	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
09b685c9-5a60-4e8e-a11e-48cd7f62eacb	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	3	0.800	339dee6f-1d8f-482c-8465-a87d2650af5e
56b81aea-6169-4ae6-af4f-89ef6bc07331	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	4	0.800	339dee6f-1d8f-482c-8465-a87d2650af5e
e6753bd6-b3f6-42a1-8c52-a294efdb5e69	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
b633ecce-5b27-4a55-b05d-a2bdd1460248	66407147-8ee2-4b34-a7e7-45d38c9e35a8	6	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
34055a41-1b53-4f89-b2b7-e1ef6b22811f	66407147-8ee2-4b34-a7e7-45d38c9e35a8	6	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6bc2cb90-a007-4f19-a0dd-9cd5933a42ab	66407147-8ee2-4b34-a7e7-45d38c9e35a8	6	3	0.338	339dee6f-1d8f-482c-8465-a87d2650af5e
86fe9466-22d0-4306-bda2-7ad9d3a6e3ee	66407147-8ee2-4b34-a7e7-45d38c9e35a8	6	4	0.624	339dee6f-1d8f-482c-8465-a87d2650af5e
f0da8216-a0fd-40b6-9d8e-646f6a93f533	66407147-8ee2-4b34-a7e7-45d38c9e35a8	6	5	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
04767f85-0992-411d-b578-08b058482282	66407147-8ee2-4b34-a7e7-45d38c9e35a8	7	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4ccdc690-dfff-402f-b78c-b48be212981f	66407147-8ee2-4b34-a7e7-45d38c9e35a8	7	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
38cd71a1-7d35-4f0c-a556-7e4d9a4305a0	66407147-8ee2-4b34-a7e7-45d38c9e35a8	7	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fa295b85-d270-496e-a7ec-7c098c43b620	66407147-8ee2-4b34-a7e7-45d38c9e35a8	7	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6c901b58-cc77-4d4e-b980-85d89e5affeb	66407147-8ee2-4b34-a7e7-45d38c9e35a8	7	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
af1b9dd0-d6d6-4ba0-a312-8eb7fb64bd9f	66407147-8ee2-4b34-a7e7-45d38c9e35a8	8	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
fd106ea7-9559-4176-a1a2-c2b5f480908c	66407147-8ee2-4b34-a7e7-45d38c9e35a8	8	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
acb9edd3-d4e1-4be7-9ade-03032aa0824d	66407147-8ee2-4b34-a7e7-45d38c9e35a8	8	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
62a6ecc4-b618-4fae-a2f8-cf5cd43ebf60	66407147-8ee2-4b34-a7e7-45d38c9e35a8	8	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
87bde665-0622-4823-9f7c-9259f656f79e	66407147-8ee2-4b34-a7e7-45d38c9e35a8	8	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
88a20f55-2875-44de-927d-1541fc1543ca	66407147-8ee2-4b34-a7e7-45d38c9e35a8	9	1	0.156	339dee6f-1d8f-482c-8465-a87d2650af5e
3234bc88-0e14-4182-800b-039a4103715d	66407147-8ee2-4b34-a7e7-45d38c9e35a8	9	2	0.260	339dee6f-1d8f-482c-8465-a87d2650af5e
38e48f97-951d-4dd1-8fe1-adbd7d43d59d	66407147-8ee2-4b34-a7e7-45d38c9e35a8	9	3	0.520	339dee6f-1d8f-482c-8465-a87d2650af5e
e8da8d0e-8cec-49e1-8d57-0bd95e34f2a7	66407147-8ee2-4b34-a7e7-45d38c9e35a8	9	4	0.208	339dee6f-1d8f-482c-8465-a87d2650af5e
e1af9da7-9db5-4087-bec0-a53caad11c37	66407147-8ee2-4b34-a7e7-45d38c9e35a8	9	5	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
9d139dcd-57c6-4921-a422-a4606fe8a087	66407147-8ee2-4b34-a7e7-45d38c9e35a8	10	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
412d9c71-17be-4436-9f0d-1b15fa3e15cb	66407147-8ee2-4b34-a7e7-45d38c9e35a8	10	2	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
deaad4c8-d93c-4edf-95f0-7b9549e7d3f1	66407147-8ee2-4b34-a7e7-45d38c9e35a8	10	3	0.208	339dee6f-1d8f-482c-8465-a87d2650af5e
94c5787a-02e4-4002-bb05-e651c84f9415	66407147-8ee2-4b34-a7e7-45d38c9e35a8	10	4	0.208	339dee6f-1d8f-482c-8465-a87d2650af5e
a67cdd60-a91d-4eb6-8cb7-5538c22021a6	66407147-8ee2-4b34-a7e7-45d38c9e35a8	10	5	0.052	339dee6f-1d8f-482c-8465-a87d2650af5e
7c4b4484-6c4c-4da0-8e81-30c9935cfa5a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	11	1	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
22eab367-6d85-4409-b644-26f1c63d5ac0	66407147-8ee2-4b34-a7e7-45d38c9e35a8	11	2	0.160	339dee6f-1d8f-482c-8465-a87d2650af5e
aaa13762-4db7-4000-a114-c531366ddece	66407147-8ee2-4b34-a7e7-45d38c9e35a8	11	3	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
4f883eb9-d63c-421c-af3c-245096e80855	66407147-8ee2-4b34-a7e7-45d38c9e35a8	11	4	0.400	339dee6f-1d8f-482c-8465-a87d2650af5e
d799f291-8af4-4f2e-980a-9f3eb7339ec5	66407147-8ee2-4b34-a7e7-45d38c9e35a8	11	5	0.100	339dee6f-1d8f-482c-8465-a87d2650af5e
d467765e-aba7-4dfc-81ea-a33f9ac999fe	66407147-8ee2-4b34-a7e7-45d38c9e35a8	12	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a897a265-205b-4bd7-8f56-7bef1c662052	66407147-8ee2-4b34-a7e7-45d38c9e35a8	12	2	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
aa6a83d1-142b-4907-95c9-6654d06b3987	66407147-8ee2-4b34-a7e7-45d38c9e35a8	12	3	0.416	339dee6f-1d8f-482c-8465-a87d2650af5e
60de4635-d62a-4edd-9324-ada71d2d956e	66407147-8ee2-4b34-a7e7-45d38c9e35a8	12	4	0.416	339dee6f-1d8f-482c-8465-a87d2650af5e
7ae6dce1-6d15-4293-a630-9bd31ed532db	66407147-8ee2-4b34-a7e7-45d38c9e35a8	12	5	0.065	339dee6f-1d8f-482c-8465-a87d2650af5e
af1218cd-3819-4e6b-9c1f-9906435633d2	66407147-8ee2-4b34-a7e7-45d38c9e35a8	13	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a21db49e-9c30-46ff-91e9-98cfbf75e2ac	66407147-8ee2-4b34-a7e7-45d38c9e35a8	13	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
67fbb072-2662-4475-ab8d-d96f4c624cad	66407147-8ee2-4b34-a7e7-45d38c9e35a8	13	3	0.312	339dee6f-1d8f-482c-8465-a87d2650af5e
6bbc1b30-d84f-4d92-9add-c07cc2c8722b	66407147-8ee2-4b34-a7e7-45d38c9e35a8	13	4	0.375	339dee6f-1d8f-482c-8465-a87d2650af5e
08b3230d-493f-4f39-b063-ab7bc357b06c	66407147-8ee2-4b34-a7e7-45d38c9e35a8	13	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ebe68287-3942-49ed-bdd8-6c59a23a4f7a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	14	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
82f5d23f-43f6-48a5-b8b9-183c4f2cae3b	66407147-8ee2-4b34-a7e7-45d38c9e35a8	14	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4dd44b58-a136-4b6d-beb4-b57db90d6bf0	66407147-8ee2-4b34-a7e7-45d38c9e35a8	14	3	0.039	339dee6f-1d8f-482c-8465-a87d2650af5e
d22eb2d7-2e7c-4544-80aa-0d4dd1809884	66407147-8ee2-4b34-a7e7-45d38c9e35a8	14	4	0.039	339dee6f-1d8f-482c-8465-a87d2650af5e
ac41ae8c-dbae-4ad4-8d29-8f48e24b9891	66407147-8ee2-4b34-a7e7-45d38c9e35a8	14	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
ae785e6f-4d65-4894-95b9-0f12504ea31a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	15	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
84001d22-f073-42c7-82c2-2abd68aabd1a	66407147-8ee2-4b34-a7e7-45d38c9e35a8	15	2	0.104	339dee6f-1d8f-482c-8465-a87d2650af5e
c4059096-1a2d-4c58-9db3-8c4974e7d3b1	66407147-8ee2-4b34-a7e7-45d38c9e35a8	15	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
69a20ae6-f2c7-42c6-8576-0c9562b0bd12	66407147-8ee2-4b34-a7e7-45d38c9e35a8	15	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
1c681500-ec0d-45ad-9926-e0cf27e70acf	66407147-8ee2-4b34-a7e7-45d38c9e35a8	15	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c9747c41-9f4b-4568-89dc-f99d946619ea	66407147-8ee2-4b34-a7e7-45d38c9e35a8	16	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
4624d408-ba62-4aea-8901-6a821edd840b	66407147-8ee2-4b34-a7e7-45d38c9e35a8	16	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
598e28ef-cc7a-469d-9117-99105d0c9bbc	66407147-8ee2-4b34-a7e7-45d38c9e35a8	16	3	0.062	339dee6f-1d8f-482c-8465-a87d2650af5e
02c384d6-6732-4699-9de9-d1983d4f33c3	66407147-8ee2-4b34-a7e7-45d38c9e35a8	16	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
de34fa8c-a8aa-4605-9f0c-2a5938267a69	66407147-8ee2-4b34-a7e7-45d38c9e35a8	16	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5b45a18f-ccc7-45dd-9aa5-d92d4baf87e6	66407147-8ee2-4b34-a7e7-45d38c9e35a8	17	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
5530e8e5-6772-435e-a0df-969cbb5d3116	66407147-8ee2-4b34-a7e7-45d38c9e35a8	17	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
014ce586-4abe-439f-9c8c-5dd6058151f8	66407147-8ee2-4b34-a7e7-45d38c9e35a8	17	3	0.078	339dee6f-1d8f-482c-8465-a87d2650af5e
ab47eb93-05e8-4e1e-92e5-069ef4c571c9	66407147-8ee2-4b34-a7e7-45d38c9e35a8	17	4	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
bdc28c78-95f8-44a6-bf76-ecd37267acd4	66407147-8ee2-4b34-a7e7-45d38c9e35a8	17	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
c7fabf7c-c776-4e29-a9e9-987994670048	66407147-8ee2-4b34-a7e7-45d38c9e35a8	18	1	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
6703a2a5-890d-4594-bf6d-b376ea7dd3ef	66407147-8ee2-4b34-a7e7-45d38c9e35a8	18	2	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
055e27a1-9828-4037-84b5-7b0a124fb5c8	66407147-8ee2-4b34-a7e7-45d38c9e35a8	18	3	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
a142bbd7-210d-488f-b676-5873ed5cfc46	66407147-8ee2-4b34-a7e7-45d38c9e35a8	18	4	0.078	339dee6f-1d8f-482c-8465-a87d2650af5e
037974e3-8325-43cb-a1f8-f0cbef82cdff	66407147-8ee2-4b34-a7e7-45d38c9e35a8	18	5	0.000	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: pursuit_staffing_meta; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pursuit_staffing_meta (pursuit_id, effective_bp_pct, calculated_bp, planned_bp_required, calculated_at, engine_version, client_id) FROM stdin;
60be7bdc-0f2e-4cc6-b340-89ca684e2705	0.009464	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
009e3647-84a5-42be-b744-db99e853d213	0.022233	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
c6643acf-9962-4fac-8d19-726aa818bbe1	0.006630	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	0.019859	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
4861aa99-4f1c-4d89-adc0-344c5e20a882	0.020000	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
eab754f9-ba9b-4824-8f79-e559ea109ed4	0.022509	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
107a8b49-cfb7-49d4-a3dd-f45d256664ae	0.010673	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
49463a9e-bc7c-4513-930a-23dd60afa6ff	0.011607	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
6a7a2c65-ff00-4138-b231-08ef30abbea6	0.066667	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
4baf4698-bff3-4fc5-b868-f8217875dc44	0.004329	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
18150d17-52ca-40d0-9ce8-dd9999cfb8a9	0.004545	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
5271fc4f-4383-41d4-a302-70be578956be	0.010284	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
d88e10f4-ec45-4477-a6e6-d7369eb2dee1	0.009872	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
17522252-395a-48b6-a72d-f4e3db3df2b4	0.009697	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
fa18eb5b-c301-4e26-93a1-021d57c20c2e	0.008185	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
ca3df605-8cd3-42cd-b7fa-06251da21bef	0.007478	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
94a133f2-836f-4d8e-a401-9cc4a5e341d5	0.012170	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
090d1fef-0165-4070-9abd-589bd74de796	0.020958	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	0.007400	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
dd490a38-e5c9-4d91-974c-9bcb31b54ac9	0.008185	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
7d16a30f-979c-44c3-8784-1045661fa333	0.021449	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
e335d212-f193-47a7-8729-8e81feffec05	0.007715	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
cd10c6b3-44f9-42dd-9c13-de9922f60581	0.006094	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
abc6a1b9-a813-4f37-8977-a310065f4d59	0.005135	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
8335a07b-0017-42a8-85dc-098013d4155d	0.014599	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
27069b0b-5405-42ba-885c-4887a2a3ef71	0.007254	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	0.007366	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
97642c0e-6ff8-4d75-b036-67ec48b7956c	0.011412	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	0.025000	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	0.021356	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
a0c1f2f8-4877-4828-baf7-e1e6d582b28e	0.015145	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
0645fe54-ce1a-4ed5-b54c-727c2abf3814	0.027027	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
fd6ac260-c2a9-468d-9371-e8715ece7666	0.033333	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
5d1abc42-9e14-47f5-92e8-a3bf03b96072	0.005627	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
5484af78-8853-475b-95c4-e6d48106a41e	0.015456	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
66407147-8ee2-4b34-a7e7-45d38c9e35a8	0.010284	\N	\N	\N	0.23	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: pursuit_year_projection; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pursuit_year_projection (id, pursuit_id, year_offset, calendar_year, billable_contract_days, probabilistic_revenue, probabilistic_fee, bp_days, bp_required, planned_investment, client_id) FROM stdin;
f4e01635-e5b5-4b5a-8663-4f83b47ae8c5	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	2	\N	0.00	0.00	0.00	53.00	140010.50	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
e27f8853-8fe2-4b88-9b6a-01919c3de557	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	3	\N	140.00	2307762.56	150004.57	18.00	47550.74	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
9ba40568-c7bc-4544-a696-a532aeb4ea09	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	4	\N	365.00	6016666.67	391083.33	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
275db636-9683-4418-8d26-e9a91c7f0335	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	5	\N	365.00	6016666.67	391083.33	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
e1d70f47-45ee-4f6c-a9a1-6f7af4b24f15	090d1fef-0165-4070-9abd-589bd74de796	1	\N	365.00	21337689.13	1386949.79	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
d6d29d59-46c9-48d5-b353-5973c80d7672	090d1fef-0165-4070-9abd-589bd74de796	2	\N	365.00	21337689.13	1386949.79	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
8d2f18cf-b437-48e4-9299-f03a6e09134d	090d1fef-0165-4070-9abd-589bd74de796	3	\N	366.00	21396148.56	1390749.66	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
8fc5a812-329e-452f-b49c-2ca9fdb9c72d	090d1fef-0165-4070-9abd-589bd74de796	4	\N	29.00	1695323.25	110196.01	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
91ac980a-b6d9-4062-aa56-b02b5de41ebc	cd10c6b3-44f9-42dd-9c13-de9922f60581	1	\N	0.00	0.00	0.00	109.00	1002195.36	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
ed258453-3e80-4626-a24b-beae7711afc0	cd10c6b3-44f9-42dd-9c13-de9922f60581	2	\N	154.00	16584141.78	1077969.22	1.00	9194.45	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
9ec898ce-9eb5-47e0-a974-db10de5e6979	cd10c6b3-44f9-42dd-9c13-de9922f60581	3	\N	366.00	39414259.03	2561926.84	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
04936c47-f95d-49b3-8a80-e23898a62176	cd10c6b3-44f9-42dd-9c13-de9922f60581	4	\N	365.00	39306569.80	2554927.04	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
bf04843e-f31b-4fe3-a382-9deb53cb62cd	cd10c6b3-44f9-42dd-9c13-de9922f60581	5	\N	365.00	39306569.80	2554927.04	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
131de3d7-8380-4528-bbce-dd3356de1f6b	5271fc4f-4383-41d4-a302-70be578956be	4	\N	291.00	10137295.08	658924.18	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
df71f156-859a-4fa8-a30f-1eccdf46fa69	5271fc4f-4383-41d4-a302-70be578956be	5	\N	75.00	2612704.92	169825.82	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
b5410dc4-b01b-457a-ab5d-bb2af4619311	17522252-395a-48b6-a72d-f4e3db3df2b4	1	\N	322.00	3703176.34	240706.46	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
1ab53b75-ea3c-47fc-94b6-84e1467e31b8	17522252-395a-48b6-a72d-f4e3db3df2b4	2	\N	365.00	4197699.89	272850.49	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
06431816-4596-4195-84a3-3066ee4af826	17522252-395a-48b6-a72d-f4e3db3df2b4	3	\N	366.00	4209200.44	273598.03	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
aa9e8186-70e6-4744-a884-dfdc51ad4ea4	17522252-395a-48b6-a72d-f4e3db3df2b4	4	\N	365.00	4197699.89	272850.49	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
69f83c35-16c8-42c3-bd8e-c5c17ffed4ef	17522252-395a-48b6-a72d-f4e3db3df2b4	5	\N	365.00	4197699.89	272850.49	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
15f2111e-27aa-43b1-9b7e-9a0f78211634	7d16a30f-979c-44c3-8784-1045661fa333	2	\N	0.00	0.00	0.00	165.00	1691887.75	1577596.82	339dee6f-1d8f-482c-8465-a87d2650af5e
7ce63668-ef82-4160-85f1-6cb2eee13760	7d16a30f-979c-44c3-8784-1045661fa333	3	\N	307.00	7286029.08	473591.89	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
c037c28d-0122-4b43-b02d-a8c5e5239f8f	7d16a30f-979c-44c3-8784-1045661fa333	4	\N	365.00	8662542.71	563065.28	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
87a8ca70-8058-48c2-9235-2b7dec469b29	7d16a30f-979c-44c3-8784-1045661fa333	5	\N	365.00	8662542.71	563065.28	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
17fe7bc0-33bf-4b91-a616-c6b4f7d817aa	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	1	\N	365.00	14174757.28	1275728.16	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
ad1bea32-c4cf-4594-a8ea-641bd2d09836	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	2	\N	262.00	10174757.28	915728.16	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
c4c4ea9e-4f23-4689-b8b5-01ec1b492e6d	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	1	\N	0.00	0.00	0.00	165.00	1708509.27	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
76ccb0bb-d1ea-403d-ae8d-eb345f49dc27	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	2	\N	154.00	5054704.60	328555.80	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
df10c985-5baf-469f-9a12-18da4911bb55	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	3	\N	366.00	12013129.10	780853.39	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
f17d84cc-8af6-442f-ad59-e88922ebea80	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	4	\N	365.00	11980306.35	778719.91	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
b40e1f9f-9145-4f23-9bf8-af6095d707d4	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	5	\N	365.00	11980306.35	778719.91	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
15490720-7390-4440-8a9a-1a4fcfaec3c8	fa18eb5b-c301-4e26-93a1-021d57c20c2e	1	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2b4d8112-5376-4be8-b5dd-34f6911cd5fd	fa18eb5b-c301-4e26-93a1-021d57c20c2e	2	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
26bbe5eb-23f7-4c4c-b858-e8eb1f81217f	fa18eb5b-c301-4e26-93a1-021d57c20c2e	3	\N	366.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
b4e09e20-9ab8-4218-8e0f-72f6de49c72d	fa18eb5b-c301-4e26-93a1-021d57c20c2e	4	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
ea1188be-7200-4321-9171-eb6fed2a9ade	fa18eb5b-c301-4e26-93a1-021d57c20c2e	5	\N	210.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a0fd110e-1c02-41e6-9275-8a298ce909dd	60be7bdc-0f2e-4cc6-b340-89ca684e2705	3	\N	20.00	462809.92	11570.25	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
d376c421-6acc-4e12-8625-d815f639f8cd	60be7bdc-0f2e-4cc6-b340-89ca684e2705	4	\N	365.00	8446280.99	211157.02	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
c9d368c8-ec7a-4da6-8d00-179c71043897	60be7bdc-0f2e-4cc6-b340-89ca684e2705	5	\N	341.00	7890909.09	197272.73	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a84424d2-840d-442a-875e-51d5b4ef4468	6a7a2c65-ff00-4138-b231-08ef30abbea6	1	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
c6fccc8d-f6d9-451b-8d02-e4150b900217	6a7a2c65-ff00-4138-b231-08ef30abbea6	2	\N	290.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
120db727-4036-4361-a6e4-e0ffcb9bd4b5	49463a9e-bc7c-4513-930a-23dd60afa6ff	1	\N	339.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
d757d57b-cc97-4f0f-9cc3-c6c94ef51a88	49463a9e-bc7c-4513-930a-23dd60afa6ff	2	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
26114f9f-220e-413e-bb62-a2dafe8f2e08	49463a9e-bc7c-4513-930a-23dd60afa6ff	3	\N	366.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
32adbb8a-7f64-40be-acce-b150e31c6ce9	49463a9e-bc7c-4513-930a-23dd60afa6ff	4	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a26bc48d-4784-43fb-a927-35270b657ccb	49463a9e-bc7c-4513-930a-23dd60afa6ff	5	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
b6353e25-8c82-4fae-8f9b-10a8646f4b0b	e335d212-f193-47a7-8729-8e81feffec05	3	\N	0.00	0.00	0.00	90.00	505106.38	2291384.73	339dee6f-1d8f-482c-8465-a87d2650af5e
58b77545-ff7c-4faa-a6b6-34a9e432e2bb	e335d212-f193-47a7-8729-8e81feffec05	4	\N	124.00	3053985.50	198509.06	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
0c1ccd54-b077-4760-b7bb-e8e728a50df1	e335d212-f193-47a7-8729-8e81feffec05	5	\N	365.00	8989554.10	584321.02	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
eaf89c6f-c252-43d3-92d4-4433a3dd1c05	ca3df605-8cd3-42cd-b7fa-06251da21bef	2	\N	0.00	0.00	0.00	93.00	560878.56	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
4e9cc6d8-db75-40d3-847f-1adc10de7288	ca3df605-8cd3-42cd-b7fa-06251da21bef	3	\N	140.00	2875136.91	186883.90	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
7fe3d2d8-9e0d-4b50-9699-90a704e2f330	ca3df605-8cd3-42cd-b7fa-06251da21bef	4	\N	365.00	7495892.66	487233.02	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
7a1dbc05-2269-4106-b546-1c296a065dfa	ca3df605-8cd3-42cd-b7fa-06251da21bef	5	\N	365.00	7495892.66	487233.02	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
c5892e9d-87d6-49db-8d0e-ed5bf553173d	abc6a1b9-a813-4f37-8977-a310065f4d59	1	\N	0.00	0.00	0.00	32.00	369291.19	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
889a7b4e-c4f6-49a0-8679-370462580a54	abc6a1b9-a813-4f37-8977-a310065f4d59	2	\N	336.00	26443190.07	1718807.35	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
3f97aa58-2b92-43bb-9e9a-e7c9b6430e5b	abc6a1b9-a813-4f37-8977-a310065f4d59	3	\N	366.00	28804189.19	1872272.30	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
25810ff9-3eaf-40c7-aff4-d3488f0046f7	abc6a1b9-a813-4f37-8977-a310065f4d59	4	\N	365.00	28725489.21	1867156.80	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
6e7df955-723c-4587-9640-d8eb6c388f87	abc6a1b9-a813-4f37-8977-a310065f4d59	5	\N	365.00	28725489.21	1867156.80	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
d67fd26d-0427-413e-9c98-5233a2f55adf	27069b0b-5405-42ba-885c-4887a2a3ef71	1	\N	0.00	0.00	0.00	62.00	403914.52	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
82a884ab-1ab5-4c1d-9874-4de0db0a64c2	27069b0b-5405-42ba-885c-4887a2a3ef71	2	\N	317.00	6660121.41	299705.46	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
edbfc2e8-ae1e-4534-9fec-65ed71a05e0a	27069b0b-5405-42ba-885c-4887a2a3ef71	3	\N	366.00	7689603.90	346032.18	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
75c35b39-1e7c-4834-a418-ff74e022c456	27069b0b-5405-42ba-885c-4887a2a3ef71	4	\N	365.00	7668594.06	345086.73	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2de053e4-a515-40b2-a8e2-5ffa77e10be0	27069b0b-5405-42ba-885c-4887a2a3ef71	5	\N	365.00	7668594.06	345086.73	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
98e08d02-ed1a-4b0f-b753-fcf042b9dded	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	1	\N	0.00	0.00	0.00	111.00	1287344.46	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
15c57b05-34a5-49a9-8f62-02448b0bf598	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	2	\N	246.00	5713114.75	371352.46	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a1e0044e-46c7-411d-a2b4-9294cb65e190	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	3	\N	366.00	8500000.00	552500.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
fa759348-9642-4d93-937a-22ddd78e7fea	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	4	\N	365.00	8476775.96	550990.44	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
e35d1fe4-4127-452d-9d1c-31894513de47	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	5	\N	304.00	7060109.29	458907.10	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
1620d16f-4448-4155-a196-e360f87f88c4	c6643acf-9962-4fac-8d19-726aa818bbe1	1	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
208eb549-fcff-40be-9273-384974f264db	c6643acf-9962-4fac-8d19-726aa818bbe1	2	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
9e8bac3d-d9fa-4a78-9c88-f8b5e2766dbd	c6643acf-9962-4fac-8d19-726aa818bbe1	3	\N	366.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
0e9aa1a8-dad4-43c7-a954-c4a5998adf45	c6643acf-9962-4fac-8d19-726aa818bbe1	4	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
e3b2a3cb-1768-4d8d-a0ff-269a1ff25ed4	c6643acf-9962-4fac-8d19-726aa818bbe1	5	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
18cbf362-1f83-4cfe-abcc-d3decaa88b97	5d1abc42-9e14-47f5-92e8-a3bf03b96072	1	\N	0.00	0.00	0.00	147.00	4501916.15	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
35131eae-c537-4e94-ae0d-aded1b3de724	5d1abc42-9e14-47f5-92e8-a3bf03b96072	2	\N	231.00	16845943.48	1684594.35	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
4fa7fb95-a1fd-47f8-870d-2dc71adac2db	5d1abc42-9e14-47f5-92e8-a3bf03b96072	3	\N	366.00	26690975.39	2669097.54	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2df98345-6f04-4e98-85bb-e9ef9dd17fef	5d1abc42-9e14-47f5-92e8-a3bf03b96072	4	\N	365.00	26618049.23	2661804.92	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
0944df4d-944c-4250-91b0-4d6672178c8e	5d1abc42-9e14-47f5-92e8-a3bf03b96072	5	\N	135.00	9845031.91	984503.19	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2af10d6d-8c2e-4743-b0ba-207c394663b3	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	1	\N	0.00	0.00	0.00	35.00	806451.61	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
38935844-cae6-42c3-8315-0cd4dadf05d8	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	2	\N	0.00	0.00	0.00	182.00	4193548.39	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
b9167ee5-4279-40e6-ac75-eebd185584b4	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	3	\N	183.00	9191780.82	597465.75	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
94e602ab-5e09-4044-87a9-725005d37bd3	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	4	\N	365.00	18333333.33	1191666.67	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
6be6eeed-6b7d-4a38-bae5-f4df975384c3	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	5	\N	365.00	18333333.33	1191666.67	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
e1b0539f-4f12-4662-9459-32f50cbcea28	4861aa99-4f1c-4d89-adc0-344c5e20a882	1	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
33cab06e-f1b1-4129-a2cf-e941f629554e	4861aa99-4f1c-4d89-adc0-344c5e20a882	2	\N	290.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
0b119510-3754-4506-9d25-4311b86e11b6	8335a07b-0017-42a8-85dc-098013d4155d	1	\N	336.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
b62a1a05-69a1-4e91-869a-8b6b03665f8e	8335a07b-0017-42a8-85dc-098013d4155d	2	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
8c70c0b2-8f76-4608-a95b-896bbc2572f8	8335a07b-0017-42a8-85dc-098013d4155d	3	\N	366.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
bf150c07-5a11-4327-b42c-5f2fe70d65ef	8335a07b-0017-42a8-85dc-098013d4155d	4	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
5b7a6a6c-ff25-4abf-85fa-37658c939479	8335a07b-0017-42a8-85dc-098013d4155d	5	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
f679df1f-7594-4b07-86eb-00217b3808ef	5484af78-8853-475b-95c4-e6d48106a41e	1	\N	0.00	0.00	0.00	111.00	1221024.05	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
cc26967e-54c1-4b3b-b27b-84bce7244630	5484af78-8853-475b-95c4-e6d48106a41e	2	\N	336.00	3631190.15	217871.41	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
d65eede0-3a09-4208-94d5-ffeb988d47b2	5484af78-8853-475b-95c4-e6d48106a41e	3	\N	366.00	3955403.56	237324.21	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
ac14e0e1-84f5-4502-8b2c-c49071db8b9b	5484af78-8853-475b-95c4-e6d48106a41e	4	\N	365.00	3944596.44	236675.79	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
7a23a72c-912a-497b-93b9-a73b1bc7009b	5484af78-8853-475b-95c4-e6d48106a41e	5	\N	365.00	3944596.44	236675.79	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
fe15bb0a-3fb7-44e3-94fa-9f4d1345f00b	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	1	\N	0.00	0.00	0.00	87.00	250000.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
c06c7da5-186c-4725-96f7-448533c7d450	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	2	\N	343.00	832524.27	54114.08	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
42740e23-9538-4bd2-91af-6d8d9e5ea261	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	3	\N	366.00	888349.51	57742.72	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
47cc79ef-9100-4717-aacb-99057247e258	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	4	\N	115.00	279126.21	18143.20	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
eb1b265c-764c-4894-a592-09846731c290	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	1	\N	0.00	0.00	0.00	63.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
fa60516b-9599-4fe1-9130-b9f1d9809d8e	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	2	\N	93.00	1357664.23	88248.18	32.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
6ae10649-4163-40b4-aad9-648b70e8577c	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	3	\N	366.00	5343065.69	347299.27	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
f57d0c51-aaa0-45fe-a283-e6ca9eb7167b	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	4	\N	365.00	5328467.15	346350.36	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
fd9a7397-c771-4103-8af4-6546d005f5ac	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	5	\N	272.00	3970802.92	258102.19	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
49dbfcfc-81cc-4711-b3fd-1ea41805cd28	0645fe54-ce1a-4ed5-b54c-727c2abf3814	2	\N	0.00	0.00	0.00	71.00	200000.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2537ea7b-16e2-4db7-82ad-44663608bd45	0645fe54-ce1a-4ed5-b54c-727c2abf3814	3	\N	306.00	309767.44	20134.88	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
7cd43ea0-b57a-484e-a561-18fab8b082b4	0645fe54-ce1a-4ed5-b54c-727c2abf3814	4	\N	365.00	369493.84	24017.10	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
4d879978-e0a2-4cb5-b771-dee35f573456	0645fe54-ce1a-4ed5-b54c-727c2abf3814	5	\N	365.00	369493.84	24017.10	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
50fed929-11f9-4161-a34e-51db3b14dfbd	66407147-8ee2-4b34-a7e7-45d38c9e35a8	2	\N	0.00	0.00	0.00	66.00	154255.15	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a230623a-70b6-4e80-8802-a4d1240de3ec	66407147-8ee2-4b34-a7e7-45d38c9e35a8	3	\N	154.00	316005.47	20540.36	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
521b898a-42b5-4f72-94ce-1fac5e7974f5	66407147-8ee2-4b34-a7e7-45d38c9e35a8	4	\N	365.00	748974.01	48683.31	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
3ef2f4cb-74aa-483a-bd0a-430387edf025	66407147-8ee2-4b34-a7e7-45d38c9e35a8	5	\N	365.00	748974.01	48683.31	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
aab03d32-2ffb-46d2-b028-37facd2bd429	97642c0e-6ff8-4d75-b036-67ec48b7956c	2	\N	0.00	0.00	0.00	101.00	616253.34	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
df6c5152-f5f0-44ae-8c42-5fb0d6f2926c	97642c0e-6ff8-4d75-b036-67ec48b7956c	3	\N	154.00	1137619.70	73945.28	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
3f77ccac-351d-403e-b223-14ad2e2ee8fc	97642c0e-6ff8-4d75-b036-67ec48b7956c	4	\N	365.00	2696306.43	175259.92	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
94d2d6f6-3a59-4fff-afc4-8aeeefc03718	97642c0e-6ff8-4d75-b036-67ec48b7956c	5	\N	365.00	2696306.43	175259.92	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
976862b4-ad35-422f-979e-af2f16e28ed7	fd6ac260-c2a9-468d-9371-e8715ece7666	2	\N	0.00	0.00	0.00	69.00	200000.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
333a607a-ea66-43d9-8b5d-fe4fc99dc595	fd6ac260-c2a9-468d-9371-e8715ece7666	3	\N	154.00	504918.03	50491.80	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
64e84544-50a0-40fb-af0e-458bb451985f	fd6ac260-c2a9-468d-9371-e8715ece7666	4	\N	212.00	695081.97	69508.20	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
ccce978e-7b27-49d6-afc9-24f939a66fe3	4baf4698-bff3-4fc5-b868-f8217875dc44	1	\N	0.00	0.00	0.00	143.00	1977530.13	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
bb6c9aa0-7869-4420-ad30-f49050caaa82	4baf4698-bff3-4fc5-b868-f8217875dc44	2	\N	294.00	11032000.26	717080.02	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
3e842353-d299-4d98-a344-eca0fb55f720	4baf4698-bff3-4fc5-b868-f8217875dc44	3	\N	366.00	13733714.61	892691.45	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
62e61b61-e11b-4235-bc59-479db4d3ea9b	4baf4698-bff3-4fc5-b868-f8217875dc44	4	\N	365.00	13696190.80	890252.40	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a19e8131-a006-42da-8ac5-b9d503ca2cfa	4baf4698-bff3-4fc5-b868-f8217875dc44	5	\N	365.00	13696190.80	890252.40	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
3f88453f-d3d0-4ac7-8ff8-be2f4d804bce	009e3647-84a5-42be-b744-db99e853d213	1	\N	0.00	0.00	0.00	163.00	1556300.62	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
1b2e9da0-8742-4065-a9be-eda1b691b63f	009e3647-84a5-42be-b744-db99e853d213	2	\N	186.00	1806660.50	117432.93	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
5e1caf05-3ae5-42f8-9084-b7ea405ec4be	009e3647-84a5-42be-b744-db99e853d213	3	\N	366.00	3555041.63	231077.71	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2138638b-8921-4ea4-a3f0-66e3da2a7b37	009e3647-84a5-42be-b744-db99e853d213	4	\N	365.00	3545328.40	230446.35	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
87df3989-93f8-45b6-b8c6-ecd19b7a7ae8	009e3647-84a5-42be-b744-db99e853d213	5	\N	164.00	1592969.47	103543.02	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
efc62846-5534-40d7-adf5-3d850c31cded	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	1	\N	0.00	0.00	0.00	24.00	115554.61	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
3c0901a7-a98e-4a55-8cb0-c604bfec1f2c	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	2	\N	0.00	0.00	0.00	61.00	293701.29	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
4cc4ad9b-9b05-4f91-aacd-072b7d0faad9	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	3	\N	336.00	1971830.99	128169.01	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
6655f44f-77d2-492c-8c65-d2c75259a6cb	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	4	\N	365.00	2142018.78	139231.22	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2b6960f8-6f9d-4c98-9324-744990ea0174	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	5	\N	365.00	2142018.78	139231.22	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
db37ff13-9631-4d51-a2df-1c534fe2e2ca	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	2	\N	0.00	0.00	0.00	95.00	580563.93	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
974ab868-218e-4baf-a592-94bab45c3bba	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	3	\N	154.00	1656614.66	157378.39	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
a452a574-ad43-4360-a242-8f546fa3cfcd	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	4	\N	365.00	3926391.90	373007.23	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
424fde9e-4822-47ae-909f-0664d3edb19e	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	5	\N	365.00	3926391.90	373007.23	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
0889591e-2d5c-47ce-a082-9fc1af7ab7af	94a133f2-836f-4d8e-a401-9cc4a5e341d5	1	\N	0.00	0.00	0.00	49.00	251095.40	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
2c9f0f85-668d-4dde-a5b8-f5af59daa0d3	94a133f2-836f-4d8e-a401-9cc4a5e341d5	2	\N	18.00	65693.43	7226.28	46.00	235722.21	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
5b560aa0-7f3a-41ec-a818-b4747697b4ed	94a133f2-836f-4d8e-a401-9cc4a5e341d5	3	\N	366.00	1335766.42	146934.31	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
8a5ae8fa-2ff6-4a53-93d2-6ac1a98daf09	94a133f2-836f-4d8e-a401-9cc4a5e341d5	4	\N	365.00	1332116.79	146532.85	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
76c7bb7b-7400-4997-9707-f2757684ec07	94a133f2-836f-4d8e-a401-9cc4a5e341d5	5	\N	347.00	1266423.36	139306.57	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
95a48002-7f9e-40b8-9ae2-459831c8b0be	107a8b49-cfb7-49d4-a3dd-f45d256664ae	2	\N	0.00	0.00	0.00	64.00	128071.46	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
49228d07-8045-4302-af99-a71b56b8855a	107a8b49-cfb7-49d4-a3dd-f45d256664ae	3	\N	340.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
8b206ff5-53ec-423b-ac73-47cd1d384fcd	107a8b49-cfb7-49d4-a3dd-f45d256664ae	4	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
23542b04-84cf-45d5-99f0-259581409ce3	107a8b49-cfb7-49d4-a3dd-f45d256664ae	5	\N	365.00	0.00	0.00	0.00	0.00	0.00	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: pwin_answer; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pwin_answer (id, pwin_assessment_id, question_id, question_option_id, numeric_value, boolean_value, client_id) FROM stdin;
911925be-c50b-4689-9de6-872765212202	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
497ca140-1db8-4ea5-a2e3-23c1f36e31d2	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
951fd0f8-f246-4f01-813f-c11b19241241	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bd6529c6-9113-4754-8027-cd067bb3869d	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
12c8893e-2821-4586-a4b9-3d05e4322a95	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7376c59a-009f-4777-a3b2-f95e7ad3b4f3	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	436c16c5-8337-42be-bf84-b07067b13f2a	27da59ac-b8b3-4e31-b767-c4f6cd8cba65	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2b11cb35-44a8-49b6-9a12-3da90583cf25	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
351b4334-58d4-4631-b461-9c84ffaaf6fc	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	efd98fee-3278-478a-b694-1e8101d0fe34	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1f5b9ced-abaf-4e02-93b0-533b87123e47	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8f1bc6c8-4e39-40ce-8a38-a01729c3008c	a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0.05	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7f5f7c74-eebb-47a7-831a-354131416b3f	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7c3f7d8d-ea0c-4eb3-a88e-cf19a8e7dfa2	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3edbae61-df78-4938-873f-498e1236da4d	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	ff325664-db23-418b-abcc-4398a5b00758	810bf1c3-efb7-4960-bebc-2aa735e3e19c	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
cad561f7-d059-4f1e-8761-47d2fa4b2e1d	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	e5715a98-a797-4e82-9a8c-4f4abd1506d5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f6319df8-664e-4240-88d1-2d3887ed28a5	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a2718bbe-3214-466b-93c6-febb95ab16ec	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8de7a18d-baac-4bfe-9c13-756ed3d518a8	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0cf87882-5a67-4761-8c22-ec532e482f5a	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
242c8f58-5f72-4133-877c-2f2114103bfc	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f3538f53-f4c3-4dd6-8d63-19e1600c2dce	cd76e7ca-cc80-4a4e-9495-1f4123a3374e	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9b34e1cc-8467-4ec9-83bc-93974dc35297	b148b833-5a6b-42c9-8096-4e2e9d1275a5	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7da6a491-e393-41e4-a276-ea0e06711534	b148b833-5a6b-42c9-8096-4e2e9d1275a5	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ccfe9904-3c91-4b11-90bd-f37c2d69eff6	b148b833-5a6b-42c9-8096-4e2e9d1275a5	ff325664-db23-418b-abcc-4398a5b00758	810bf1c3-efb7-4960-bebc-2aa735e3e19c	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6c652be1-6928-4a41-98ff-b0e8a3e057b6	b148b833-5a6b-42c9-8096-4e2e9d1275a5	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	aa73e26c-1529-498f-b21a-7271e60abe11	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9bf09292-87f5-4206-8f34-626f1b4331ac	b148b833-5a6b-42c9-8096-4e2e9d1275a5	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
821068fe-125b-4f65-b88e-7dc5f1f01df6	b148b833-5a6b-42c9-8096-4e2e9d1275a5	436c16c5-8337-42be-bf84-b07067b13f2a	b5588961-363c-4d17-aa85-61c5c277ac05	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5eaed2b9-87b8-4f96-8b1f-6df72c72cb3a	b148b833-5a6b-42c9-8096-4e2e9d1275a5	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
830e3d47-f7b7-4a84-b0b8-d707f0f35c81	b148b833-5a6b-42c9-8096-4e2e9d1275a5	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	df768dd0-8d2e-4460-afe8-61603dfb8a65	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
993dfad4-6789-4de3-b27a-0aad2602d78e	b148b833-5a6b-42c9-8096-4e2e9d1275a5	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0927c332-e81b-4bb3-9ea1-5bb1f9f2647b	b148b833-5a6b-42c9-8096-4e2e9d1275a5	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0.02	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d065913e-b965-4c11-81b3-e9cb4e77abb2	0e2b95f9-b782-404a-b920-6b5184646517	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fd4d5ba1-b55e-40f3-a6ec-e7f2bcf5fa78	0e2b95f9-b782-404a-b920-6b5184646517	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
54ef2172-df6d-4338-a9c5-3f4808a22d9d	0e2b95f9-b782-404a-b920-6b5184646517	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
35001a7b-d91a-4956-8ba9-fcaeeeb76050	0e2b95f9-b782-404a-b920-6b5184646517	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
403304b3-5ada-45fc-9a0d-5d999ac521a7	0e2b95f9-b782-404a-b920-6b5184646517	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9c3377d6-91fb-4c23-a448-2f3dd24f1432	0e2b95f9-b782-404a-b920-6b5184646517	436c16c5-8337-42be-bf84-b07067b13f2a	b5588961-363c-4d17-aa85-61c5c277ac05	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5e202f37-f4fc-41d5-a96a-12991113289a	0e2b95f9-b782-404a-b920-6b5184646517	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
04d74e0e-aafb-4060-8006-aaca493dc9e0	0e2b95f9-b782-404a-b920-6b5184646517	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	229b460e-e662-480a-9907-e4cfbeef6c51	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
95f9a2c8-a592-4185-8955-8325cb821dad	0e2b95f9-b782-404a-b920-6b5184646517	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
067acb0c-5838-4f39-b9a4-03e2b47b17ce	0e2b95f9-b782-404a-b920-6b5184646517	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0.01	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fe506c1e-46ed-4a8d-97ed-9ad74206407a	62419cb5-0081-4e44-af11-9fb94d019fcd	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b61e9c98-1bda-4387-9651-ac8893a7f4bf	62419cb5-0081-4e44-af11-9fb94d019fcd	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1191d45b-d268-4e9d-a3d6-eb2067f15389	62419cb5-0081-4e44-af11-9fb94d019fcd	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9181b0da-1225-40f6-a2e5-b488c4d37ec3	62419cb5-0081-4e44-af11-9fb94d019fcd	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
581c857f-d25c-4c9a-b8c9-6e41910666bf	62419cb5-0081-4e44-af11-9fb94d019fcd	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8e41a1df-293e-4528-ae97-bbe28b77aa79	62419cb5-0081-4e44-af11-9fb94d019fcd	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b189e0ea-edc4-4680-a27c-f37ce0ab8518	62419cb5-0081-4e44-af11-9fb94d019fcd	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
732512e5-3b4f-4997-b21d-de5b5edfde9c	62419cb5-0081-4e44-af11-9fb94d019fcd	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
72529f20-4e98-4a49-8624-7135cadd4ad4	62419cb5-0081-4e44-af11-9fb94d019fcd	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f7e2112f-8db7-425f-8f37-a1019b20452c	62419cb5-0081-4e44-af11-9fb94d019fcd	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4f79aaeb-fd33-4458-9e3a-337a62606b5b	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
75693c96-a3d2-4d7d-a5c1-f785d911b9a0	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8b70f619-0f51-4849-a225-ff40b7fb21a0	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5a76cafe-972f-4118-9bb8-c890e733cbc2	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
952f6a46-bf90-40d5-8179-ee7cc0af06f9	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b048ccef-29f5-48aa-90d3-314a37f4a160	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
db1153ec-e677-46f9-98e5-56f4a366ecc7	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1bc5b084-4f76-481a-b18c-4d0df6d991d8	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	7d7c1ef9-0f81-4868-bcbf-98da89e499a7	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7d4643b5-9036-4936-8d4f-c73ca6814d89	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3e4e99bd-dcd0-472c-896d-42c7f23ddb80	0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d99085ac-92d9-4345-ba32-91be8e32f8ef	06a9faa2-29df-470d-bd14-9f9378620f8b	91dd3856-6efa-4315-b902-ff6f1b5c3b06	ede89e31-a852-4977-96d3-598f46201964	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
528326ba-1b57-4ef0-8856-fdcb19a4a022	06a9faa2-29df-470d-bd14-9f9378620f8b	b323af7c-2260-405d-a344-b1e19f61630a	f8805822-b881-46f8-aaf7-fd1776dd7e9a	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
482d6802-a666-49d9-bf88-90e5a7d10eb4	06a9faa2-29df-470d-bd14-9f9378620f8b	ff325664-db23-418b-abcc-4398a5b00758	810bf1c3-efb7-4960-bebc-2aa735e3e19c	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
971e806d-ee8a-454b-9730-c9c7e384456b	06a9faa2-29df-470d-bd14-9f9378620f8b	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	aa73e26c-1529-498f-b21a-7271e60abe11	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b94320f5-54c7-42d9-adaf-7caa528ac8aa	06a9faa2-29df-470d-bd14-9f9378620f8b	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d4601e0d-9c83-4f8a-944d-e940120cf8a6	06a9faa2-29df-470d-bd14-9f9378620f8b	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f5d3f0c7-b1f3-40c6-a1d6-2d24660e8d54	06a9faa2-29df-470d-bd14-9f9378620f8b	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e281eedb-19c6-4cc2-86a1-29a396d17f28	06a9faa2-29df-470d-bd14-9f9378620f8b	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5db8cf1a-d202-4178-865a-8c4be3473c23	06a9faa2-29df-470d-bd14-9f9378620f8b	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0f1db958-ea94-42c3-ba14-45f6436cfcfd	06a9faa2-29df-470d-bd14-9f9378620f8b	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e5a1703d-2701-44eb-8ccc-3268ef9dd075	65588d20-f91e-446c-a2bb-f23516354a4c	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
15cdfe65-ecdd-48af-a6d8-d896ca6d5036	65588d20-f91e-446c-a2bb-f23516354a4c	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
dbd81e27-0a77-4e9f-a40d-36eebfd0badc	65588d20-f91e-446c-a2bb-f23516354a4c	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
973b42c5-5d75-42b5-9893-b41fdf228278	65588d20-f91e-446c-a2bb-f23516354a4c	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
17365c26-3c83-4d6c-ba4b-35a38d7df4b9	65588d20-f91e-446c-a2bb-f23516354a4c	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
69985568-12e0-4056-bb23-bf106be94330	65588d20-f91e-446c-a2bb-f23516354a4c	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
01ba8f95-9c78-4591-bd8f-8b8269f53b1d	65588d20-f91e-446c-a2bb-f23516354a4c	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2f8e8c43-5268-4bc3-bdc8-533b3ef2ac23	65588d20-f91e-446c-a2bb-f23516354a4c	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2cf3932b-5bf8-41ec-865c-9d1475d19c83	65588d20-f91e-446c-a2bb-f23516354a4c	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
de41fdad-4c4e-4021-ac1b-cce9665f5dca	65588d20-f91e-446c-a2bb-f23516354a4c	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f5304329-7129-4edf-bcde-fadd33d4abec	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
55aa9271-d4bb-438c-af90-e474f331a875	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2a2d65e6-3f9d-4638-a215-277821a396c9	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e86d2a55-cf78-4656-a0f6-8d2bf8da91ca	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
eb9bf417-4455-48fa-9081-572341f79c79	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d268e54c-51d0-44d7-8cc7-df4e5e46624c	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6f1a52b3-6b77-4506-8cda-e34f7a731559	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
257d2cff-35f6-435a-a7fa-ff379c288fa3	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c6a9779c-ac83-43b8-8899-c8eaf1a3389f	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9152ddb7-4fa1-4d65-8ddd-335294293524	7c03a933-ebf1-48f8-a4d4-abff91aebdf0	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b359c23c-cd46-45a3-bfcc-4df2c055e08a	d817e1e8-af5e-4900-adfd-5da2b634ace4	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4ef3a141-57c9-4f4e-8f11-0dc809180aa1	d817e1e8-af5e-4900-adfd-5da2b634ace4	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c70e9b4b-fc8c-4388-bf50-d81224cd5011	d817e1e8-af5e-4900-adfd-5da2b634ace4	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b6fe2dc7-2dae-4e25-9063-72d6c63be75d	d817e1e8-af5e-4900-adfd-5da2b634ace4	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
06626335-9ff6-4514-b21f-e9b81c5d75bc	d817e1e8-af5e-4900-adfd-5da2b634ace4	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7e45721f-c633-4fd3-bcbc-7392bd4d2820	d817e1e8-af5e-4900-adfd-5da2b634ace4	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8a85312f-eebd-420e-8462-95206b051ac9	d817e1e8-af5e-4900-adfd-5da2b634ace4	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5dc96ef7-dcc0-4ae8-b3d1-66bf8c03d111	d817e1e8-af5e-4900-adfd-5da2b634ace4	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b5874590-8c6f-4811-8eea-63bebfccf497	d817e1e8-af5e-4900-adfd-5da2b634ace4	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
210e7cb1-f3a2-4520-be9c-c1d812ea619f	d817e1e8-af5e-4900-adfd-5da2b634ace4	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
eb9284e6-08c5-4e8d-9d54-71fdb28dc641	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
57db475b-40d0-42d8-8609-3839adaff7a2	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	b323af7c-2260-405d-a344-b1e19f61630a	f8805822-b881-46f8-aaf7-fd1776dd7e9a	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4463c543-0937-4c3d-9e5e-4955f084b477	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3f16a2d7-21de-47db-a628-e354c8d4626f	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
40a88ffc-e4f0-4f6d-a849-d8279ce12edf	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7e368c07-a1f7-40fd-87fc-5f2ad716dd9e	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9994475c-ea6e-4232-b90a-c9d7d951a87b	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f28b6358-d0c4-42a1-b097-14836ce1e187	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
86b3d402-6e4d-40c9-b86b-87986f25489c	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ae7d7a06-6d76-423e-b113-2f4371a3b451	7f606d63-8527-4d0c-a47a-4fb541c1b1d4	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a5de3a4e-d2d1-4f71-bd72-536357210fc7	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
db9db898-925c-4515-9b11-8dd04a0e0a6a	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f16331b7-fa3d-444a-8ca7-7019e26fe5bc	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f56cc9a5-68d2-4999-85bb-1f5118d476ac	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ff3ff210-8a9c-424d-b55a-9c1d457c0d23	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
30ec6cb5-8e88-45e4-ad93-ed34ee2eb78b	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b8a39b0e-9c90-4aff-acfe-1965c7b6e215	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
71990343-d4e6-4817-ab34-0f66de8c2fa9	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7cfe4496-ef73-4ab9-8d3c-1d226f6939c5	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a4dd875a-d991-47de-9e14-16453b10a037	9b5d65ef-1bc4-483b-bc75-cf6503bac71d	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bbfc9859-c5c9-4b45-b930-77f7a304afc2	0df0c6f1-273b-4928-95f2-8cc30e972751	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
be90e6c9-63cf-48ec-8d25-9165aae1194e	0df0c6f1-273b-4928-95f2-8cc30e972751	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1e2f6e5b-c360-42a8-98fc-ef64b95dac9d	0df0c6f1-273b-4928-95f2-8cc30e972751	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1a9edcd5-eb59-4bb1-83d1-bb3804ed22d1	0df0c6f1-273b-4928-95f2-8cc30e972751	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b771bc3a-3922-46e0-911c-ed9c916481e4	0df0c6f1-273b-4928-95f2-8cc30e972751	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e2b10b11-232a-4029-ad56-a84da58c0677	0df0c6f1-273b-4928-95f2-8cc30e972751	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
224977fb-b7fb-44f9-b339-f70eedb673e1	0df0c6f1-273b-4928-95f2-8cc30e972751	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
385eca33-c47e-4f9c-9b96-040c7693e302	0df0c6f1-273b-4928-95f2-8cc30e972751	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0cec03b5-eea8-494f-9503-20b8083c7d24	0df0c6f1-273b-4928-95f2-8cc30e972751	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e5a04b43-ef95-4e68-83c5-efdc1ecd22d1	0df0c6f1-273b-4928-95f2-8cc30e972751	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b5806016-4911-444e-be12-c5c8b3425b23	89df645e-92dc-436f-b922-34199e3708db	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bf4e7cca-367b-432b-8f73-7a0af9b4974a	89df645e-92dc-436f-b922-34199e3708db	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
324a7bfe-7cea-400f-a9c6-6da958591069	89df645e-92dc-436f-b922-34199e3708db	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d5c4332b-81d9-41c3-973e-7b1b825a85e2	89df645e-92dc-436f-b922-34199e3708db	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b2540631-671f-46b9-91cd-9ecdb7f6afcd	89df645e-92dc-436f-b922-34199e3708db	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0d7cc624-037a-4d91-8dae-99cf52bbfb57	89df645e-92dc-436f-b922-34199e3708db	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7bd652f1-249d-41a5-af74-b635d2c46892	89df645e-92dc-436f-b922-34199e3708db	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8f45c188-9e35-4ef7-a4d3-99332b59f851	89df645e-92dc-436f-b922-34199e3708db	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bb1e180e-b6cc-43ac-bd42-96092b104395	89df645e-92dc-436f-b922-34199e3708db	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7a71dea4-a097-4fd9-8c53-cb5cbd807216	89df645e-92dc-436f-b922-34199e3708db	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
afc382a7-4836-4a50-adb4-f6b143b5fd0a	6d69f89b-d865-42bb-928f-a3beb1d05902	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a4647bfd-3370-4e58-8c58-041b18b64e0f	6d69f89b-d865-42bb-928f-a3beb1d05902	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0e52568e-40c0-4aa9-ab8f-929e873a25e1	6d69f89b-d865-42bb-928f-a3beb1d05902	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
29f916a9-915c-4689-9821-5ee0ae13994d	6d69f89b-d865-42bb-928f-a3beb1d05902	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9b21a400-4ccf-4dcf-a0a7-c1807fb6dd9d	6d69f89b-d865-42bb-928f-a3beb1d05902	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f726f0a5-1f18-44cf-a59c-6c89a4fdcacd	6d69f89b-d865-42bb-928f-a3beb1d05902	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
105c59c0-2172-41a6-9b5d-ae6fac8fc746	6d69f89b-d865-42bb-928f-a3beb1d05902	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
de256576-be21-4d50-950d-6dd35eaf0bbc	6d69f89b-d865-42bb-928f-a3beb1d05902	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b6754ab3-32b0-4fe2-8572-cb771946fb05	6d69f89b-d865-42bb-928f-a3beb1d05902	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8dca5c0d-cbc5-4e92-a576-c71cd969d7fa	6d69f89b-d865-42bb-928f-a3beb1d05902	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a0125425-f47d-4e23-b4aa-7c08a5eb4e3e	49d6f258-b9c1-4942-a65e-82b477b0ea5f	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
86245285-2d5d-4424-aa4f-12cdf2c8a3ff	49d6f258-b9c1-4942-a65e-82b477b0ea5f	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8e52e6be-febc-4562-8c3f-e1ed00c8fa22	49d6f258-b9c1-4942-a65e-82b477b0ea5f	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d54849b4-c525-4e36-95ee-e2262b249af0	49d6f258-b9c1-4942-a65e-82b477b0ea5f	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e3869306-eb7e-4166-86a7-cf27840553aa	49d6f258-b9c1-4942-a65e-82b477b0ea5f	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4e55e9ca-0433-4739-96cb-872c10f41ea2	49d6f258-b9c1-4942-a65e-82b477b0ea5f	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
93e4ce97-62c3-4853-9bd5-abc511ee3186	49d6f258-b9c1-4942-a65e-82b477b0ea5f	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
715e6ccc-3b49-4e63-8d6b-dea09245a45e	49d6f258-b9c1-4942-a65e-82b477b0ea5f	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
78c60134-c122-4b41-9401-86cc53d3c749	49d6f258-b9c1-4942-a65e-82b477b0ea5f	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
66f03a3d-ed7e-4aae-94dc-eabd6e0a1e88	49d6f258-b9c1-4942-a65e-82b477b0ea5f	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6c7fd4d9-60b2-4a95-8162-a7b7632dac9e	3d686504-7a04-4246-9169-48d4eed1af29	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f4c0ed43-1d02-44eb-abf7-5348302330df	3d686504-7a04-4246-9169-48d4eed1af29	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1db70a39-ecd7-487c-b676-8c4bbdca8e66	3d686504-7a04-4246-9169-48d4eed1af29	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
812178e2-e8c3-4fbb-afd7-71168e2d8351	3d686504-7a04-4246-9169-48d4eed1af29	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f453ace2-ee8d-4c35-93cf-0ec86c86b6b9	3d686504-7a04-4246-9169-48d4eed1af29	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
37c86cdf-f22f-4749-bcc8-8bf987b009e1	3d686504-7a04-4246-9169-48d4eed1af29	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f4d0a853-9e15-4d90-9c3f-9ce62c833a70	3d686504-7a04-4246-9169-48d4eed1af29	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
230efd6e-8a6b-45b2-b6c0-94ecaf7fdf7b	3d686504-7a04-4246-9169-48d4eed1af29	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1b1d568d-c330-4a6b-910c-05cf322e09d1	3d686504-7a04-4246-9169-48d4eed1af29	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f005c4cb-347d-48ee-b001-5901ccb19d16	3d686504-7a04-4246-9169-48d4eed1af29	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
402f87ac-1ea4-41f7-800f-ed4573b5b15c	1aab71eb-abdb-42b6-aebc-f305316699d1	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9688a12b-4f4e-4e35-8354-c48b3babdd1e	1aab71eb-abdb-42b6-aebc-f305316699d1	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9da9392b-4597-4ad2-900d-665cedf34b52	1aab71eb-abdb-42b6-aebc-f305316699d1	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c7e3e16c-8b03-4308-911f-4c0ed7809951	1aab71eb-abdb-42b6-aebc-f305316699d1	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8fd8f2fc-751b-498e-bd53-8bda8f1f28dd	1aab71eb-abdb-42b6-aebc-f305316699d1	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	f9c82115-5316-4fce-b5ca-c75894591a8d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
93f65387-5736-418a-8933-9e18015b585b	1aab71eb-abdb-42b6-aebc-f305316699d1	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1a5fa3a8-00d7-4db9-9d04-45cd21ca5212	1aab71eb-abdb-42b6-aebc-f305316699d1	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
46f6f53e-34b7-491e-8cdf-c846942789d2	1aab71eb-abdb-42b6-aebc-f305316699d1	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	24164a9a-fbcf-4773-8f38-891d50e4b53e	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
69e207b6-2cc2-4495-aa16-d63bbbe19705	1aab71eb-abdb-42b6-aebc-f305316699d1	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8c7adbd6-7564-48fa-aabe-9f1b7de4dca8	1aab71eb-abdb-42b6-aebc-f305316699d1	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
cae93249-5abb-4e42-98d9-0debff518aeb	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
34a935ce-2bff-4473-9ca2-9b8c96ce76c6	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
311892a4-8bab-4cdb-8ed2-3c20322a887c	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8fc2289d-f46e-4f8d-84f5-8d7dbf9b530f	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b577775a-f4c2-42f9-ab99-0881c5ed3a9b	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7b67bb30-81cb-41c1-ad10-c3b0f1e20cff	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5a8f4c85-68a6-451b-bc52-446fdb48e3cf	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c232e505-9ec5-4f05-9c97-b40886f59669	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9f9c0be2-2cbc-456b-8bbc-95d19e71e976	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3ee09132-df6f-45d3-b0a6-05eba9752960	6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4149e85e-9832-4ce7-a4b3-f494c7314ea8	cb898313-1f26-4be1-9c2a-abd3682a6ee5	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
88ba48a0-d3a6-4654-9e95-366cf02a0596	cb898313-1f26-4be1-9c2a-abd3682a6ee5	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
710ae65b-04e0-4bdc-8b61-5f3c9f4c14b6	cb898313-1f26-4be1-9c2a-abd3682a6ee5	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
53017450-4b45-42de-a0ad-38b2af92e21b	cb898313-1f26-4be1-9c2a-abd3682a6ee5	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7df19a66-66f9-4121-9d6e-054faa36424a	cb898313-1f26-4be1-9c2a-abd3682a6ee5	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
86feae53-05b8-49e8-b149-263b776cef13	cb898313-1f26-4be1-9c2a-abd3682a6ee5	436c16c5-8337-42be-bf84-b07067b13f2a	0e5a3ff7-4614-4d37-9956-77e26d7492da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9d85bd65-a5d3-44f6-8ed1-cc20b97b8c0f	cb898313-1f26-4be1-9c2a-abd3682a6ee5	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6668aedf-1b15-4c40-a1c0-8eb7c17c4cf6	cb898313-1f26-4be1-9c2a-abd3682a6ee5	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
124ca782-c4ce-4f44-88cc-6efe5389a902	cb898313-1f26-4be1-9c2a-abd3682a6ee5	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
101173bb-d6c7-48d9-9ae7-32b1fb265af6	cb898313-1f26-4be1-9c2a-abd3682a6ee5	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0.035	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
97bc1586-2604-4398-98fc-c2ddabb01a17	295df286-4ef9-4dbc-8827-9cc713997d66	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
647834dc-d897-4cbe-b24d-d9d70968d74d	295df286-4ef9-4dbc-8827-9cc713997d66	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b14fdb59-d9a0-404b-87b3-1e7644d3092b	295df286-4ef9-4dbc-8827-9cc713997d66	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b2a252bb-a4e5-4f2d-86f9-144ed0b8a514	295df286-4ef9-4dbc-8827-9cc713997d66	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
67b5d990-1c78-4419-ad81-e60248d072f4	295df286-4ef9-4dbc-8827-9cc713997d66	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	f9c82115-5316-4fce-b5ca-c75894591a8d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6a908103-59a2-4b00-a4ca-41c448a05f7d	295df286-4ef9-4dbc-8827-9cc713997d66	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
98b92e5d-3480-4aa8-8b0e-d00aaff373be	295df286-4ef9-4dbc-8827-9cc713997d66	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e8087f79-c659-4afe-b4ec-98624f5ad03f	295df286-4ef9-4dbc-8827-9cc713997d66	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	24164a9a-fbcf-4773-8f38-891d50e4b53e	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d4b569fc-20ba-4744-a234-f7093ca2b231	295df286-4ef9-4dbc-8827-9cc713997d66	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b91226d6-4d52-4ee2-9449-cdf24acbc27e	295df286-4ef9-4dbc-8827-9cc713997d66	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b37e11ef-6538-4467-bc6b-9c69a4249581	479841a1-b03d-48e2-bd99-921d4e28ae30	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
419ee037-daeb-4387-b3c6-299e784ce0ad	479841a1-b03d-48e2-bd99-921d4e28ae30	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
27e26496-85f1-4f73-adaf-d63cd15bb10a	479841a1-b03d-48e2-bd99-921d4e28ae30	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
571f8395-71e0-40f4-a937-a26f12ae3838	479841a1-b03d-48e2-bd99-921d4e28ae30	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a9e4c34e-5a61-4523-ac14-f979568a2ad8	479841a1-b03d-48e2-bd99-921d4e28ae30	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7868591f-ded2-4be5-8658-b557716f32a8	479841a1-b03d-48e2-bd99-921d4e28ae30	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3c811f77-b7ce-40e6-a6d0-d6a28c861cba	479841a1-b03d-48e2-bd99-921d4e28ae30	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a6521a95-b84f-46e7-b8d2-58eab68982df	479841a1-b03d-48e2-bd99-921d4e28ae30	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
71a14c20-6d80-482a-98af-486fae0dc7d9	479841a1-b03d-48e2-bd99-921d4e28ae30	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4b6e51b9-2c0a-444f-804e-2ae0e27d96fd	479841a1-b03d-48e2-bd99-921d4e28ae30	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2504e6b6-a643-410a-b281-6e521262aaed	ac254a0c-10b2-4448-ac07-162551345de9	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
935eba8a-6a34-4e37-985a-a137cca79279	ac254a0c-10b2-4448-ac07-162551345de9	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
466aafa6-d7b6-4cc7-ba66-ec26e17c8bc8	ac254a0c-10b2-4448-ac07-162551345de9	ff325664-db23-418b-abcc-4398a5b00758	810bf1c3-efb7-4960-bebc-2aa735e3e19c	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
05d8ce35-d56b-4072-a976-8c93d32ef2c6	ac254a0c-10b2-4448-ac07-162551345de9	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	aa73e26c-1529-498f-b21a-7271e60abe11	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
feb44a4d-82d0-4327-81db-7f75f65dc231	ac254a0c-10b2-4448-ac07-162551345de9	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ddde09e7-768c-4a84-8207-665b61f555a4	ac254a0c-10b2-4448-ac07-162551345de9	436c16c5-8337-42be-bf84-b07067b13f2a	b5588961-363c-4d17-aa85-61c5c277ac05	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1f7d7607-c6ac-4a48-be38-5f0a2aac8199	ac254a0c-10b2-4448-ac07-162551345de9	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6bd92c3d-e916-4700-a9d0-47d42f0a2ba1	ac254a0c-10b2-4448-ac07-162551345de9	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
22939a9d-012a-454d-84a7-79ce14b16ca5	ac254a0c-10b2-4448-ac07-162551345de9	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d18d3526-7ade-45f4-89a4-f13307bd3d3a	ac254a0c-10b2-4448-ac07-162551345de9	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0.02	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fa1c7c75-b01f-4ab2-9c11-52eae3893135	343f0813-b779-4547-a793-618fd5b149ee	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f3f53068-1160-4b0d-a46f-b93d507aba40	343f0813-b779-4547-a793-618fd5b149ee	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
227ae514-6951-400e-b93c-226cd0b42cd9	343f0813-b779-4547-a793-618fd5b149ee	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
24c84f0f-31c7-4cba-9caf-f315a10038b2	343f0813-b779-4547-a793-618fd5b149ee	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	f0292610-de8d-4ae3-9d8f-331c27d0c3a5	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5f23574b-f9d9-4a4c-be25-385e2bee8338	343f0813-b779-4547-a793-618fd5b149ee	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f52c3703-032d-40d5-a277-2c8aea3f21ff	343f0813-b779-4547-a793-618fd5b149ee	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d3ba011b-3c78-41b9-b200-be69012d214f	343f0813-b779-4547-a793-618fd5b149ee	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
126c6840-0cfd-476d-a60a-5a4bc04c9078	343f0813-b779-4547-a793-618fd5b149ee	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
86ce78d7-b241-457e-9746-7fd909c88aa0	343f0813-b779-4547-a793-618fd5b149ee	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3cde117d-ec42-4329-b45c-91509065dbc0	343f0813-b779-4547-a793-618fd5b149ee	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e6b327ea-5f7d-47f9-b769-55699a07d1b9	9d821745-74b3-4ab5-80bf-7c9d377a3905	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
41e8d424-1a69-48d6-9d08-20e230753153	9d821745-74b3-4ab5-80bf-7c9d377a3905	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2c53d632-524a-477d-b916-69a724167dd1	9d821745-74b3-4ab5-80bf-7c9d377a3905	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
75880434-0109-423a-ac4c-e13f3ef55202	9d821745-74b3-4ab5-80bf-7c9d377a3905	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e4f6beea-bd70-423b-a84e-46abeca1def9	9d821745-74b3-4ab5-80bf-7c9d377a3905	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fb36fb75-c072-495b-88df-293df66be4dd	9d821745-74b3-4ab5-80bf-7c9d377a3905	436c16c5-8337-42be-bf84-b07067b13f2a	0e5a3ff7-4614-4d37-9956-77e26d7492da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0b57d806-8380-4e91-8b2e-b533667a2db9	9d821745-74b3-4ab5-80bf-7c9d377a3905	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5a13a22a-148d-4428-9164-00b17e83d1bb	9d821745-74b3-4ab5-80bf-7c9d377a3905	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
daaad395-3b7e-4f11-b31a-78a9c7d64bec	9d821745-74b3-4ab5-80bf-7c9d377a3905	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ec6d2f6b-b67d-41c6-a931-92df8969699b	9d821745-74b3-4ab5-80bf-7c9d377a3905	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0.035	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6fa9f1b7-0c87-40eb-ac8b-506be48b154a	ed461c65-7262-4655-b3d0-59d8d92837d6	91dd3856-6efa-4315-b902-ff6f1b5c3b06	120d8852-cf51-43bd-952f-a86d40391278	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
db1a5e0b-32eb-49ad-bc26-03f20ddef153	ed461c65-7262-4655-b3d0-59d8d92837d6	b323af7c-2260-405d-a344-b1e19f61630a	dbab0e3a-e2b0-4396-b9f4-5742febf6377	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fa65cc7b-f742-4acf-909b-2b4d27836013	ed461c65-7262-4655-b3d0-59d8d92837d6	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f9acbdb3-bd9a-4bba-8c30-550aece58c36	ed461c65-7262-4655-b3d0-59d8d92837d6	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bfdd1387-5f3f-4cfc-a283-e4fe8af15cb2	ed461c65-7262-4655-b3d0-59d8d92837d6	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7ae2985b-c947-4de8-9937-5671801db1ce	ed461c65-7262-4655-b3d0-59d8d92837d6	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8c0ced37-6041-4c68-86e2-32514dc58e1a	ed461c65-7262-4655-b3d0-59d8d92837d6	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
36748958-3580-4629-9307-ba288eb123d9	ed461c65-7262-4655-b3d0-59d8d92837d6	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d11d0bef-0de1-4fbb-adfc-b2091b80dd87	ed461c65-7262-4655-b3d0-59d8d92837d6	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
817349f3-2797-4028-8b6a-61d0a86a85b8	ed461c65-7262-4655-b3d0-59d8d92837d6	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
941fefea-67bb-40a2-b96c-fa258b5ac325	6d0f0f22-adc2-40ba-a717-b742f15e40be	91dd3856-6efa-4315-b902-ff6f1b5c3b06	ede89e31-a852-4977-96d3-598f46201964	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8a6a46bd-54ac-405a-a7e9-7d6263a58815	6d0f0f22-adc2-40ba-a717-b742f15e40be	b323af7c-2260-405d-a344-b1e19f61630a	dbab0e3a-e2b0-4396-b9f4-5742febf6377	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f6c45f78-31a5-4f30-86a2-e6d19ed9cd11	6d0f0f22-adc2-40ba-a717-b742f15e40be	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a7eebae2-11ee-4c4f-b779-b8d249be457e	6d0f0f22-adc2-40ba-a717-b742f15e40be	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5129c293-8fcd-42f1-8152-a999a24aaa0b	6d0f0f22-adc2-40ba-a717-b742f15e40be	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0153c975-8bc1-4844-8e68-733fc938ef66	6d0f0f22-adc2-40ba-a717-b742f15e40be	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
93636590-ca4d-4b18-bf84-fff671a33285	6d0f0f22-adc2-40ba-a717-b742f15e40be	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a03d2d76-886a-4230-9aee-1429e2f20754	6d0f0f22-adc2-40ba-a717-b742f15e40be	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7c81d856-d4cc-42e5-95b4-1bb65fbf3c3e	6d0f0f22-adc2-40ba-a717-b742f15e40be	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
dbcbed03-6b80-469c-b43f-3c5cb116ee24	6d0f0f22-adc2-40ba-a717-b742f15e40be	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
88b9b53c-3365-4b53-8d8e-f86535120f22	50c22350-41bb-42f1-b7ef-9224b29d700a	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
54a09cc5-d139-422c-904f-3b529ee4119f	50c22350-41bb-42f1-b7ef-9224b29d700a	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3238b934-8ce6-4257-91be-c92c1cfa9e64	50c22350-41bb-42f1-b7ef-9224b29d700a	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
745d9f45-43a1-41be-9a30-cc6c0e88e332	50c22350-41bb-42f1-b7ef-9224b29d700a	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7b25eb79-a707-4f3b-a3f1-d56e348b6c42	50c22350-41bb-42f1-b7ef-9224b29d700a	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6939ddba-0f7b-4b71-8970-0492f83bc6fc	50c22350-41bb-42f1-b7ef-9224b29d700a	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1ccaec3d-3976-481a-98a7-d8426d3ab06e	50c22350-41bb-42f1-b7ef-9224b29d700a	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
38c802e4-676e-4d3c-83af-4c5c54c26be6	50c22350-41bb-42f1-b7ef-9224b29d700a	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d595fa6d-d12c-441f-970e-285f1256564b	50c22350-41bb-42f1-b7ef-9224b29d700a	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d016ea85-8cb4-48d5-a904-c589e6fdffe5	50c22350-41bb-42f1-b7ef-9224b29d700a	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e0476a08-5a0b-4d54-ac0b-bbe44737c1ef	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	91dd3856-6efa-4315-b902-ff6f1b5c3b06	ede89e31-a852-4977-96d3-598f46201964	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4d148661-0902-4222-ae7f-8fbed6544b5f	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bc7ceb78-755e-4d7d-b355-919afacc44b5	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8b54b5a6-9a41-441d-890a-0f19e8567459	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7fb0a6ee-da81-4211-8077-d3ab159f9211	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
de195ac2-0272-4475-9261-21d2737b10e7	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7c3188e9-1935-414a-9909-7020d478496d	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
497b1ec9-1f8c-4d68-841e-d074f01bdb13	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	df768dd0-8d2e-4460-afe8-61603dfb8a65	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2006d25a-eb41-41cb-a075-3a183b053c27	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
03a61093-6d58-4cc4-baeb-c1c87625b385	a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2da01731-21bf-48dc-b0e4-c109e70fce8f	3150942c-5fdb-4576-a112-71a6b056fded	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bc29519d-6e3f-4895-a9fd-55db9acf0d15	3150942c-5fdb-4576-a112-71a6b056fded	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
84f6b036-bad6-4a9b-abf3-074843ca5055	3150942c-5fdb-4576-a112-71a6b056fded	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7c7aaadb-c0e2-4d4e-92c6-b482ce7252d6	3150942c-5fdb-4576-a112-71a6b056fded	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a2ffb5fd-087b-4fee-9b12-2817c050310a	3150942c-5fdb-4576-a112-71a6b056fded	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0427c514-f1aa-4bbd-95b2-278bb4b24f06	3150942c-5fdb-4576-a112-71a6b056fded	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c7fc143e-16cb-4004-9b9a-6f07c1d8b220	3150942c-5fdb-4576-a112-71a6b056fded	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
313166b0-488f-4061-9930-c08691ad5084	3150942c-5fdb-4576-a112-71a6b056fded	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6201461e-1471-4f1c-b866-1d6658b9c889	3150942c-5fdb-4576-a112-71a6b056fded	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5e1c56ac-d9c4-4de5-ab85-a2a40e4107a0	3150942c-5fdb-4576-a112-71a6b056fded	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
41dcf29f-1c80-46f5-b463-143b4aa41bbd	1b578260-65c8-42d4-95f2-cb41164ed916	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c6e38e7b-34da-443f-b00a-d456c2d9d473	1b578260-65c8-42d4-95f2-cb41164ed916	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fe043f21-a711-426f-a4f8-0d4e6c885dd6	1b578260-65c8-42d4-95f2-cb41164ed916	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
94b80b76-f684-49b0-a14e-8a555ec1b173	1b578260-65c8-42d4-95f2-cb41164ed916	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
131a2dca-be69-4b15-b516-ee6dba76056c	1b578260-65c8-42d4-95f2-cb41164ed916	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
24150578-d97a-4750-b43e-4f8cddf4e53f	1b578260-65c8-42d4-95f2-cb41164ed916	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5677a284-0282-41a8-9b45-df002a2f5da1	1b578260-65c8-42d4-95f2-cb41164ed916	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
77991a14-4dd3-4af4-8a78-b393afdc6614	1b578260-65c8-42d4-95f2-cb41164ed916	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4a53b3ac-ea9e-4f5b-8dc9-ee89d8aaa698	1b578260-65c8-42d4-95f2-cb41164ed916	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3b13b710-8300-408f-84da-d971c509dc82	1b578260-65c8-42d4-95f2-cb41164ed916	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5e428b08-e523-48dc-ab20-c71b05a6fa60	b2751706-1996-455e-8ec1-603c5f176281	91dd3856-6efa-4315-b902-ff6f1b5c3b06	0e9fd123-08ba-472e-bf5a-1c0dab128bae	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
21c13018-419d-43b9-b6f5-e925209ac271	b2751706-1996-455e-8ec1-603c5f176281	b323af7c-2260-405d-a344-b1e19f61630a	b12eeb2c-87f5-4a45-be08-812aad7e28da	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f6391540-f746-4070-baf7-c9c70d048371	b2751706-1996-455e-8ec1-603c5f176281	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
541bcd54-f901-4ccf-ad2e-ca06ce0334a5	b2751706-1996-455e-8ec1-603c5f176281	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
27265f05-bfaa-490f-8d73-827490b56667	b2751706-1996-455e-8ec1-603c5f176281	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
cd0c3722-2818-4b2d-9c10-4aa2077c025d	b2751706-1996-455e-8ec1-603c5f176281	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
081797ea-a016-4fc8-b0ff-4d72b05f184a	b2751706-1996-455e-8ec1-603c5f176281	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ffd5e8e5-d8d9-4d2b-b7cd-250c74955b17	b2751706-1996-455e-8ec1-603c5f176281	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
791ad8b0-1601-43de-9350-f8d69484ef2f	b2751706-1996-455e-8ec1-603c5f176281	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2aa1187a-1dcf-45e8-8151-694728ebe1a1	b2751706-1996-455e-8ec1-603c5f176281	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7803e841-1cff-497f-95c9-bdaabfe33d5c	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
81db9dee-40c1-43de-8105-851b3eb92290	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9afc7c5f-5bd0-4bd8-bc5e-03d69305973d	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
11f8a94c-0a92-4e44-af2b-624c88b387ff	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
94f0d7f9-846b-47f3-8c1f-a3d7b644792b	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2b3b8e25-14ee-4a57-9c08-9cf4ffdd84bf	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
98d41ed4-56db-4e1b-a619-81434843151b	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	effe972c-cd15-439f-8983-095b228b1fd1	d5223fc3-f784-48d8-bd2c-5af4296b27aa	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ef30cbe5-e2b0-4e2a-a233-2ec255e3d118	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
34e5f7a6-e7ae-4bc0-b2ba-e572ba6bf667	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ccc68dcf-076b-4e84-8447-d6e11a760a86	1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
00671078-7cfd-4a6d-8b8f-2b63ef27d64b	8aefa386-b80c-44d5-a456-e47b1f6b0979	91dd3856-6efa-4315-b902-ff6f1b5c3b06	120d8852-cf51-43bd-952f-a86d40391278	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b092aefe-2189-4310-bf57-0363eed76b5d	8aefa386-b80c-44d5-a456-e47b1f6b0979	b323af7c-2260-405d-a344-b1e19f61630a	dbab0e3a-e2b0-4396-b9f4-5742febf6377	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f6f20279-609b-49b9-8ed3-30560598e533	8aefa386-b80c-44d5-a456-e47b1f6b0979	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
bbb6c8fc-67fe-4a13-8046-732f723359b8	8aefa386-b80c-44d5-a456-e47b1f6b0979	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fb9c3dff-5723-4380-a910-a43f5c34b8b0	8aefa386-b80c-44d5-a456-e47b1f6b0979	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f01eaead-3c9e-4468-bd86-ee9b995789b3	8aefa386-b80c-44d5-a456-e47b1f6b0979	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
21374658-2760-40ec-9bab-26fa221a9b3b	8aefa386-b80c-44d5-a456-e47b1f6b0979	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
26dca11b-9098-4223-9ecc-728cd898e2a2	8aefa386-b80c-44d5-a456-e47b1f6b0979	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8b275054-570a-4478-b65f-af5ec2423fd4	8aefa386-b80c-44d5-a456-e47b1f6b0979	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
311ed81f-806c-4771-a3d3-9cd3989fd124	8aefa386-b80c-44d5-a456-e47b1f6b0979	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ab8d3da4-d2d1-4cfc-9cd1-74f5ec380748	90570e03-ef1d-4bee-8d34-229756915bd7	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4b67bb62-77e3-463b-a9f1-2608df5ac660	90570e03-ef1d-4bee-8d34-229756915bd7	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6b7ae701-b7df-4235-b871-d2b566cab8c8	90570e03-ef1d-4bee-8d34-229756915bd7	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f1a2eec4-d3ad-48ad-a4da-d9c9407fa8ac	90570e03-ef1d-4bee-8d34-229756915bd7	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f5374bfb-2ad7-45ed-9353-d936551c6f49	90570e03-ef1d-4bee-8d34-229756915bd7	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3832e28b-f587-4fa9-9540-41c8a9dc490b	90570e03-ef1d-4bee-8d34-229756915bd7	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9e4755d5-1806-4e74-b176-9af4afbc2b5c	90570e03-ef1d-4bee-8d34-229756915bd7	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f38a5510-49f6-4dd8-a7ae-bd4d505556c3	90570e03-ef1d-4bee-8d34-229756915bd7	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6c228f11-5e3f-49df-84b1-470a420e056e	90570e03-ef1d-4bee-8d34-229756915bd7	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	d95a4792-77fc-4a16-8f15-77db0d605d76	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c653dca8-ddcb-4f7f-bcde-bde9aff35a6e	90570e03-ef1d-4bee-8d34-229756915bd7	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
909f3247-9e40-42e0-8d80-ebc37a5a0eec	37d7b269-927f-43c2-8068-8bdcecdbef72	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8213b021-10e6-4756-a553-1818fdeb3b09	37d7b269-927f-43c2-8068-8bdcecdbef72	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7929ba0e-07b5-40da-9dae-6b8f44f28615	37d7b269-927f-43c2-8068-8bdcecdbef72	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
171e6779-74a6-4612-af10-2869bfdfdd44	37d7b269-927f-43c2-8068-8bdcecdbef72	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c7fe21b3-45a1-444d-b239-7113e3e743db	37d7b269-927f-43c2-8068-8bdcecdbef72	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8a9fe055-106f-4573-8778-2bf919aa2086	37d7b269-927f-43c2-8068-8bdcecdbef72	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8c3e10e8-52d2-4193-b3d8-d0dc52987a8c	37d7b269-927f-43c2-8068-8bdcecdbef72	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
108a8a8a-b0a2-4f1b-bbd0-4dc61fc22104	37d7b269-927f-43c2-8068-8bdcecdbef72	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3984cd5d-9cd3-4c51-8e4f-717b208896aa	37d7b269-927f-43c2-8068-8bdcecdbef72	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c2675926-8527-4a00-b0d9-546851e994a6	37d7b269-927f-43c2-8068-8bdcecdbef72	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
2ffd7383-ddef-4540-b0f0-e9a8667d10b7	5163264c-43bf-4806-bfb3-bbd878a15c66	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7fca0dc8-7420-42dd-a889-e158c784656d	5163264c-43bf-4806-bfb3-bbd878a15c66	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
4341d281-3db7-4089-8aa7-788c876bc121	5163264c-43bf-4806-bfb3-bbd878a15c66	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8170c2d9-5855-4e31-84c4-c6c9a721ae21	5163264c-43bf-4806-bfb3-bbd878a15c66	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9ce7d4b4-dd0d-48f1-a84a-2042c7e17a58	5163264c-43bf-4806-bfb3-bbd878a15c66	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
599b6b6f-451e-4166-a104-683852e64140	5163264c-43bf-4806-bfb3-bbd878a15c66	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d1942f74-e90e-4cb7-9d54-fd413aea3361	5163264c-43bf-4806-bfb3-bbd878a15c66	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d3516a1f-1655-4971-ae24-c5af1ac86924	5163264c-43bf-4806-bfb3-bbd878a15c66	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
87573729-952d-43cf-a3f7-f222cce0948c	5163264c-43bf-4806-bfb3-bbd878a15c66	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
707fda9f-9f1c-4552-9dda-92d21dae38c8	5163264c-43bf-4806-bfb3-bbd878a15c66	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f61d4eee-2884-45e5-af69-5ac0c4b3da0b	b1b19aa3-799e-438b-b037-f85c901c57e2	91dd3856-6efa-4315-b902-ff6f1b5c3b06	eecfbd95-f0b3-4639-81db-e77949db6afd	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e564480e-f110-4f10-aea5-f0db44b0b9e4	b1b19aa3-799e-438b-b037-f85c901c57e2	b323af7c-2260-405d-a344-b1e19f61630a	f235b60a-6d80-4015-90fc-60fb2a010d33	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b8748e76-c62f-47f6-9168-ef8dbf938d34	b1b19aa3-799e-438b-b037-f85c901c57e2	ff325664-db23-418b-abcc-4398a5b00758	3298ab30-6412-4094-8880-829263239f3d	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
f30ea825-c2b5-43f7-b2c5-20df8697fad5	b1b19aa3-799e-438b-b037-f85c901c57e2	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	4d601a0a-b366-4db3-b44f-fac0245ff5cc	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
187167c8-30a1-49bb-abde-3d5bd9b54d96	b1b19aa3-799e-438b-b037-f85c901c57e2	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
e16fc348-8981-43b7-8efd-c7a80a5f7b37	b1b19aa3-799e-438b-b037-f85c901c57e2	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c902d40a-2e9e-4d4d-83ec-d85634c71b27	b1b19aa3-799e-438b-b037-f85c901c57e2	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
576c621a-3634-4cbc-aedf-fcdc0fd0b8fd	b1b19aa3-799e-438b-b037-f85c901c57e2	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	3cd5483f-4011-481c-a1de-e732a77f90d3	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
52526b5a-d44e-4c1d-a3e3-b35cdc059d9b	b1b19aa3-799e-438b-b037-f85c901c57e2	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	10f4136e-3993-40cc-b5a7-23e64f780239	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
87525860-6c65-4628-b06c-515c45edfd43	b1b19aa3-799e-438b-b037-f85c901c57e2	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
635113ba-eb69-455f-b260-51a2ceb0c7df	459de3fd-51bd-4a26-b0d9-46ef88b9224e	91dd3856-6efa-4315-b902-ff6f1b5c3b06	f3dd3617-4f28-4772-ad80-3b26a2297229	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
50c23dc4-2ba8-4dd2-bc0b-6528d9514932	459de3fd-51bd-4a26-b0d9-46ef88b9224e	b323af7c-2260-405d-a344-b1e19f61630a	d379964a-b7ca-4e43-96e4-9c94a0478205	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ddf67186-506f-41bc-b7d7-1f5814584931	459de3fd-51bd-4a26-b0d9-46ef88b9224e	ff325664-db23-418b-abcc-4398a5b00758	f3a2dd2c-8e9e-481b-9139-0338d5d18383	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0915adaf-1bd1-4cf8-87eb-ba4365d7f3cd	459de3fd-51bd-4a26-b0d9-46ef88b9224e	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	58c192b1-4b86-4957-8198-257088d0abed	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3736a35e-6c75-45b6-9919-597d10f3be04	459de3fd-51bd-4a26-b0d9-46ef88b9224e	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	cae0cf55-d06a-42c3-a8f9-db203beb9755	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
fde0edb6-22e8-417c-b1e2-64ef11c0cd39	459de3fd-51bd-4a26-b0d9-46ef88b9224e	436c16c5-8337-42be-bf84-b07067b13f2a	57c54976-43ff-4e2a-b51d-3eae255986ca	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8a3e07f9-64bb-4b38-8bee-c8289110c607	459de3fd-51bd-4a26-b0d9-46ef88b9224e	effe972c-cd15-439f-8983-095b228b1fd1	4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
c996e422-41a6-4622-affa-c276265d5baf	459de3fd-51bd-4a26-b0d9-46ef88b9224e	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	df768dd0-8d2e-4460-afe8-61603dfb8a65	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9a5985de-4999-4193-a272-73b7c668ce35	459de3fd-51bd-4a26-b0d9-46ef88b9224e	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	d95a4792-77fc-4a16-8f15-77db0d605d76	\N	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
83096260-e07b-45fe-800a-2ba62c092000	459de3fd-51bd-4a26-b0d9-46ef88b9224e	e35cae8a-f358-4e40-bb44-14a874c72d9c	\N	0	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: pwin_assessment; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.pwin_assessment (id, pursuit_id, questionnaire_version_id, engine_version, calculated_at, calculated_by, pwin, base_pwin, score_tech, score_mgmt, score_past_perf, price_position, competitor_price_position, engine_request, engine_response, is_current, scenario, blended_pwin, client_id) FROM stdin;
a40d65ef-2ad0-40bd-8bf1-f5a1153e8006	60be7bdc-0f2e-4cc6-b340-89ca684e2705	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.712150	0.712150	100.000	85.000	85.000	-0.065000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
cd76e7ca-cc80-4a4e-9495-1f4123a3374e	009e3647-84a5-42be-b744-db99e853d213	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.136375	0.136375	80.000	80.000	90.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b148b833-5a6b-42c9-8096-4e2e9d1275a5	c6643acf-9962-4fac-8d19-726aa818bbe1	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.295775	0.295775	82.500	75.000	85.000	-0.030000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0e2b95f9-b782-404a-b920-6b5184646517	7fb51b43-a3ed-43ec-8efd-ca7cfe038f34	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.735175	0.735175	102.500	95.000	85.000	0.010000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
62419cb5-0081-4e44-af11-9fb94d019fcd	4861aa99-4f1c-4d89-adc0-344c5e20a882	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	0.193750	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0bfbf4f7-3bb0-4ce7-88f9-664428c76aca	eab754f9-ba9b-4824-8f79-e559ea109ed4	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.495100	0.495100	95.000	95.000	85.000	-0.010000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
06a9faa2-29df-470d-bd14-9f9378620f8b	107a8b49-cfb7-49d4-a3dd-f45d256664ae	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.017057	0.017057	65.000	65.000	85.000	0.080000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
65588d20-f91e-446c-a2bb-f23516354a4c	49463a9e-bc7c-4513-930a-23dd60afa6ff	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.564025	0.564025	95.000	95.000	90.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7c03a933-ebf1-48f8-a4d4-abff91aebdf0	6a7a2c65-ff00-4138-b231-08ef30abbea6	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.564025	0.564025	95.000	95.000	90.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
d817e1e8-af5e-4900-adfd-5da2b634ace4	4baf4698-bff3-4fc5-b868-f8217875dc44	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.170400	0.170400	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
7f606d63-8527-4d0c-a47a-4fb541c1b1d4	18150d17-52ca-40d0-9ce8-dd9999cfb8a9	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.031833	0.031833	80.000	80.000	85.000	0.080000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9b5d65ef-1bc4-483b-bc75-cf6503bac71d	5271fc4f-4383-41d4-a302-70be578956be	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.841000	0.841000	95.000	95.000	90.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
0df0c6f1-273b-4928-95f2-8cc30e972751	d88e10f4-ec45-4477-a6e6-d7369eb2dee1	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.710300	0.710300	95.000	95.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
89df645e-92dc-436f-b922-34199e3708db	17522252-395a-48b6-a72d-f4e3db3df2b4	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.785000	0.785000	95.000	95.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6d69f89b-d865-42bb-928f-a3beb1d05902	fa18eb5b-c301-4e26-93a1-021d57c20c2e	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.710300	0.710300	95.000	95.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
49d6f258-b9c1-4942-a65e-82b477b0ea5f	ca3df605-8cd3-42cd-b7fa-06251da21bef	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.506519	0.464500	95.000	95.000	85.000	0.000000	0.000000	\N	\N	t	BASE	0.506519	339dee6f-1d8f-482c-8465-a87d2650af5e
3d686504-7a04-4246-9169-48d4eed1af29	ca3df605-8cd3-42cd-b7fa-06251da21bef	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.718975	\N	95.000	95.000	85.000	0.000000	0.000000	\N	\N	t	DEPENDENT_WON	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1aab71eb-abdb-42b6-aebc-f305316699d1	94a133f2-836f-4d8e-a401-9cc4a5e341d5	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.089500	0.089500	87.500	90.000	87.500	0.030000	-0.100000	\N	\N	t	BASE	0.089500	339dee6f-1d8f-482c-8465-a87d2650af5e
6f564ff8-b9b3-4a49-bab2-cecfd81cd3dd	94a133f2-836f-4d8e-a401-9cc4a5e341d5	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	\N	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	DEPENDENT_WON	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
cb898313-1f26-4be1-9c2a-abd3682a6ee5	090d1fef-0165-4070-9abd-589bd74de796	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.841600	0.841600	105.000	95.000	90.000	-0.017500	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
295df286-4ef9-4dbc-8827-9cc713997d66	bdc681d7-75a7-4bf6-81d5-b06829f3fb9a	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.134500	0.134500	87.500	90.000	87.500	0.030000	-0.100000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
479841a1-b03d-48e2-bd99-921d4e28ae30	dd490a38-e5c9-4d91-974c-9bcb31b54ac9	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.165120	0.165120	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ac254a0c-10b2-4448-ac07-162551345de9	7d16a30f-979c-44c3-8784-1045661fa333	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.564025	0.090425	82.500	75.000	80.000	-0.010000	0.000000	\N	\N	t	BASE	0.564025	339dee6f-1d8f-482c-8465-a87d2650af5e
343f0813-b779-4547-a793-618fd5b149ee	7d16a30f-979c-44c3-8784-1045661fa333	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.564025	\N	95.000	95.000	90.000	0.000000	0.000000	\N	\N	t	DEPENDENT_WON	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
9d821745-74b3-4ab5-80bf-7c9d377a3905	e335d212-f193-47a7-8729-8e81feffec05	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.547200	0.547200	95.000	85.000	85.000	-0.017500	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
ed461c65-7262-4655-b3d0-59d8d92837d6	cd10c6b3-44f9-42dd-9c13-de9922f60581	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.851800	0.851800	95.000	95.000	85.000	-0.080000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
6d0f0f22-adc2-40ba-a717-b742f15e40be	abc6a1b9-a813-4f37-8977-a310065f4d59	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.396625	0.396625	85.000	85.000	85.000	-0.080000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
50c22350-41bb-42f1-b7ef-9224b29d700a	8335a07b-0017-42a8-85dc-098013d4155d	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	0.193750	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
a6ccc2d2-3375-43d9-8be4-8ab6e7b56a10	27069b0b-5405-42ba-885c-4887a2a3ef71	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.360000	0.360000	80.000	80.000	85.000	0.008000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
3150942c-5fdb-4576-a112-71a6b056fded	60c6ee1c-39b0-4f6e-b675-d50a3ed69a2c	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	0.193750	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1b578260-65c8-42d4-95f2-cb41164ed916	97642c0e-6ff8-4d75-b036-67ec48b7956c	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	0.193750	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b2751706-1996-455e-8ec1-603c5f176281	66407147-8ee2-4b34-a7e7-45d38c9e35a8	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	0.193750	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
1e0f0f4b-ac5c-41fe-901a-34a72283d1f8	f93cb916-e9fc-4778-81c5-fb2a6a43c2ec	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.193750	0.193750	85.000	85.000	85.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
8aefa386-b80c-44d5-a456-e47b1f6b0979	51c039ab-bdb0-40ac-9fef-1ae4238ebaa0	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.767925	0.767925	95.000	95.000	80.000	-0.080000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
90570e03-ef1d-4bee-8d34-229756915bd7	a0c1f2f8-4877-4828-baf7-e1e6d582b28e	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.370825	0.370825	85.000	85.000	80.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
37d7b269-927f-43c2-8068-8bdcecdbef72	0645fe54-ce1a-4ed5-b54c-727c2abf3814	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.175825	0.175825	85.000	85.000	80.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
5163264c-43bf-4806-bfb3-bbd878a15c66	fd6ac260-c2a9-468d-9371-e8715ece7666	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.175825	0.175825	85.000	85.000	80.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
b1b19aa3-799e-438b-b037-f85c901c57e2	5d1abc42-9e14-47f5-92e8-a3bf03b96072	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.117850	0.117850	80.000	80.000	80.000	0.000000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
459de3fd-51bd-4a26-b0d9-46ef88b9224e	5484af78-8853-475b-95c4-e6d48106a41e	0cd1f7b2-11af-4e07-a735-a893daef4f34	0.23	2026-08-25 20:26:34.20537+00	\N	0.215875	0.215875	85.000	85.000	80.000	-0.020000	0.000000	\N	\N	t	BASE	\N	339dee6f-1d8f-482c-8465-a87d2650af5e
\.


--
-- Data for Name: question; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.question (id, questionnaire_version_id, code, display_order, prompt_text, help_text, answer_type, is_required, numeric_min, numeric_max, section) FROM stdin;
91dd3856-6efa-4315-b902-ff6f1b5c3b06	0cd1f7b2-11af-4e07-a735-a893daef4f34	TM1A	1	(varies by opportunity type -- see question_prompt_variant)	\N	single_select	t	\N	\N	Technical & Management
b323af7c-2260-405d-a344-b1e19f61630a	0cd1f7b2-11af-4e07-a735-a893daef4f34	TM1B	2	(varies by opportunity type -- see question_prompt_variant)	\N	single_select	t	\N	\N	Technical & Management
ff325664-db23-418b-abcc-4398a5b00758	0cd1f7b2-11af-4e07-a735-a893daef4f34	TM2	3	2.  Is there an incumbent?	\N	single_select	t	\N	\N	Technical & Management
57746f7e-64b5-400b-b4cb-9f70bdfcdad6	0cd1f7b2-11af-4e07-a735-a893daef4f34	TM3	4	3.  Is the incumbent well-performing?	\N	single_select	t	\N	\N	Technical & Management
1b0f63b8-e261-416f-9a7b-0e185bf8e6de	0cd1f7b2-11af-4e07-a735-a893daef4f34	TM4	5	4.  Will we need a teammate in order to bid key aspects of the job?	\N	single_select	t	\N	\N	Technical & Management
436c16c5-8337-42be-bf84-b07067b13f2a	0cd1f7b2-11af-4e07-a735-a893daef4f34	TM5	6	5.  Do we plan to invest (other than B&P) to increase competitiveness prior to RFP release?	\N	single_select	t	\N	\N	Technical & Management
e35cae8a-f358-4e40-bb44-14a874c72d9c	0cd1f7b2-11af-4e07-a735-a893daef4f34	INVEST_PCT	7	Investment percentage (fraction of award value)	\N	numeric	t	\N	\N	Technical & Management
effe972c-cd15-439f-8983-095b228b1fd1	0cd1f7b2-11af-4e07-a735-a893daef4f34	PP1	8	1.  Do we have any performance issues on similar contracts within the last 3 years?	\N	single_select	t	\N	\N	Past Performance
d68dd786-2d78-42c7-bfe4-aee3ead1b34f	0cd1f7b2-11af-4e07-a735-a893daef4f34	P1	9	1.  How far above/below a normal bid are we planning for this proposal?	\N	single_select	t	\N	\N	Price
7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	0cd1f7b2-11af-4e07-a735-a893daef4f34	P2	10	2.  Is this Best Value or LPTA?	\N	single_select	t	\N	\N	Price
\.


--
-- Data for Name: question_dependency; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.question_dependency (id, question_id, depends_on_question_id, trigger_option_id, effect) FROM stdin;
307cac4f-7258-48c1-9b4f-2b2b18b1eb53	91dd3856-6efa-4315-b902-ff6f1b5c3b06	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	d95a4792-77fc-4a16-8f15-77db0d605d76	DISABLE
002a17b2-cfb6-4fda-bfaa-861a9fa8ed89	b323af7c-2260-405d-a344-b1e19f61630a	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	d95a4792-77fc-4a16-8f15-77db0d605d76	DISABLE
\.


--
-- Data for Name: question_option; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.question_option (id, question_id, code, label_text, engine_value, display_order, is_active, applies_to_type_group) FROM stdin;
0e9fd123-08ba-472e-bf5a-1c0dab128bae	91dd3856-6efa-4315-b902-ff6f1b5c3b06	SAME	Same	Same	1	t	PRODUCT
120d8852-cf51-43bd-952f-a86d40391278	91dd3856-6efa-4315-b902-ff6f1b5c3b06	BETTER	Better	Better	2	t	PRODUCT
ede89e31-a852-4977-96d3-598f46201964	91dd3856-6efa-4315-b902-ff6f1b5c3b06	WORSE	Worse	Worse	3	t	PRODUCT
f3dd3617-4f28-4772-ad80-3b26a2297229	91dd3856-6efa-4315-b902-ff6f1b5c3b06	ON_CONTRACT_TODAY	On contract today	On contract today	1	t	SERVICES
ee126b00-0f9d-445b-b6cd-94fc77ffffb1	91dd3856-6efa-4315-b902-ff6f1b5c3b06	YES_FEWER_BLOCKS	Yes, but not as many building blocks as competitor	Yes, but not as many building blocks as competitor	2	t	SERVICES
1ad07f83-f819-4aa9-b9ff-14562a3ae2b4	91dd3856-6efa-4315-b902-ff6f1b5c3b06	NO_TEAMMATES_ON_CONTRACT	No, but our teammates are on contract today	No, but our teammates are on contract today	3	t	SERVICES
eecfbd95-f0b3-4639-81db-e77949db6afd	91dd3856-6efa-4315-b902-ff6f1b5c3b06	NO	No	No	4	t	SERVICES
b12eeb2c-87f5-4a45-be08-812aad7e28da	b323af7c-2260-405d-a344-b1e19f61630a	SAME_LEVEL	Same Level	Same Level	1	t	PRODUCT
dbab0e3a-e2b0-4396-b9f4-5742febf6377	b323af7c-2260-405d-a344-b1e19f61630a	MORE_MATURE	More Mature	More Mature	2	t	PRODUCT
f8805822-b881-46f8-aaf7-fd1776dd7e9a	b323af7c-2260-405d-a344-b1e19f61630a	LESS_MATURE	Less Mature	Less Mature	3	t	PRODUCT
d379964a-b7ca-4e43-96e4-9c94a0478205	b323af7c-2260-405d-a344-b1e19f61630a	ON_CONTRACT_TODAY	On contract today	On contract today	1	t	SERVICES
b417e776-ac49-4929-840f-0f58d8517fe4	b323af7c-2260-405d-a344-b1e19f61630a	YES_FEWER_BLOCKS_THAN_US	Yes, but not as many building blocks as us	Yes, but not as many building blocks as us	2	t	SERVICES
f235b60a-6d80-4015-90fc-60fb2a010d33	b323af7c-2260-405d-a344-b1e19f61630a	NO	No	No	3	t	SERVICES
3298ab30-6412-4094-8880-829263239f3d	ff325664-db23-418b-abcc-4398a5b00758	YES_US	Yes, us	Yes, us	1	t	\N
810bf1c3-efb7-4960-bebc-2aa735e3e19c	ff325664-db23-418b-abcc-4398a5b00758	YES_COMPETITOR	Yes, one of the competitors	Yes, one of the competitors	2	t	\N
f3a2dd2c-8e9e-481b-9139-0338d5d18383	ff325664-db23-418b-abcc-4398a5b00758	NO	No	No	3	t	\N
f0292610-de8d-4ae3-9d8f-331c27d0c3a5	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	WE_SATISFACTORY	We are performing satisfactorily/unknown	We are performing satisfactorily/unknown	1	t	\N
4d601a0a-b366-4db3-b44f-fac0245ff5cc	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	WE_ISSUES	We have performance issues	We have performance issues	2	t	\N
58c192b1-4b86-4957-8198-257088d0abed	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	NA	N/A	N/A	3	t	\N
aa73e26c-1529-498f-b21a-7271e60abe11	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	INCUMBENT_SATISFACTORY	Incumbent competitor is performing satisfactorily/unknown	Incumbent competitor is performing satisfactorily/unknown	4	t	\N
e5715a98-a797-4e82-9a8c-4f4abd1506d5	57746f7e-64b5-400b-b4cb-9f70bdfcdad6	INCUMBENT_ISSUES	Incumbent competitor has performance issues	Incumbent competitor has performance issues	5	t	\N
f9c82115-5316-4fce-b5ca-c75894591a8d	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	YES_MOST	Yes, we will outsource most of the actual work requested ("noble work")	Yes, we will outsource most of the actual work requested ("noble work")	1	t	\N
54f3f644-76c1-470a-96a5-83d58c09c8ac	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	YES_SOME	Yes, we will outsource some of the actual work requested ("noble work")	Yes, we will outsource some of the actual work requested ("noble work")	2	t	\N
cae0cf55-d06a-42c3-a8f9-db203beb9755	1b0f63b8-e261-416f-9a7b-0e185bf8e6de	NO	No	No	3	t	\N
57c54976-43ff-4e2a-b51d-3eae255986ca	436c16c5-8337-42be-bf84-b07067b13f2a	NO	No	No	1	t	\N
b5588961-363c-4d17-aa85-61c5c277ac05	436c16c5-8337-42be-bf84-b07067b13f2a	LOW	Low	Low	2	t	\N
0e5a3ff7-4614-4d37-9956-77e26d7492da	436c16c5-8337-42be-bf84-b07067b13f2a	MODERATE	Moderate	Moderate	3	t	\N
27da59ac-b8b3-4e31-b767-c4f6cd8cba65	436c16c5-8337-42be-bf84-b07067b13f2a	HIGH	High	High	4	t	\N
4988e3c3-dc73-4dfd-8eee-13fa13dd3e25	effe972c-cd15-439f-8983-095b228b1fd1	YES	Yes	Yes	1	t	\N
d5223fc3-f784-48d8-bd2c-5af4296b27aa	effe972c-cd15-439f-8983-095b228b1fd1	NO	No	No	2	t	\N
24164a9a-fbcf-4773-8f38-891d50e4b53e	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	ABOVE_3	3% above normal	3% above normal	1	t	\N
18a5cd32-014a-4c95-9eff-1d591355664b	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	ABOVE_2	2% above normal	2% above normal	2	t	\N
229b460e-e662-480a-9907-e4cfbeef6c51	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	ABOVE_1	1% above normal	1% above normal	3	t	\N
3cd5483f-4011-481c-a1de-e732a77f90d3	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	NORMAL	Normal Bid	Normal Bid	4	t	\N
7d7c1ef9-0f81-4868-bcbf-98da89e499a7	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	LOWER_1	1% lower than normal	1% lower than normal	5	t	\N
df768dd0-8d2e-4460-afe8-61603dfb8a65	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	LOWER_2	2% lower than normal	2% lower than normal	6	t	\N
620f15a7-29c9-448a-b920-a55ae24c41ba	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	LOWER_3	3% lower than normal	3% lower than normal	7	t	\N
efd98fee-3278-478a-b694-1e8101d0fe34	d68dd786-2d78-42c7-bfe4-aee3ead1b34f	LOWER_4	4% lower than normal	4% lower than normal	8	t	\N
10f4136e-3993-40cc-b5a7-23e64f780239	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	BEST_VALUE	Best Value	Best Value	1	t	\N
d95a4792-77fc-4a16-8f15-77db0d605d76	7ba9ba9c-f4ee-416a-9ada-f2323d78d20a	LPTA	LPTA	LPTA	2	t	\N
\.


--
-- Data for Name: question_prompt_variant; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.question_prompt_variant (id, question_id, type_group, prompt_text, help_text) FROM stdin;
9f3abbc8-71a5-4ce5-be1a-bffd97577286	91dd3856-6efa-4315-b902-ff6f1b5c3b06	PRODUCT	1a.  Does our product perform better than our competitor?	\N
5217dfab-7ee5-4d2a-b8f0-b19c7f419772	91dd3856-6efa-4315-b902-ff6f1b5c3b06	SERVICES	1a.  Have we done a job like this before?	\N
316b95a7-1ec7-4a5d-873b-360a40faa203	b323af7c-2260-405d-a344-b1e19f61630a	PRODUCT	1b.  Is our Technical Solution more mature than competitors?	\N
84b1beb8-645e-4ef2-a0f5-6eff92cb788b	b323af7c-2260-405d-a344-b1e19f61630a	SERVICES	1b.  Have our competitors done a job like this before?	\N
\.


--
-- Data for Name: questionnaire_version; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.questionnaire_version (id, code, version_no, engine_version, effective_from, is_active, notes) FROM stdin;
0cd1f7b2-11af-4e07-a735-a893daef4f34	pwin	1	0.23	2026-01-01	t	Extracted from workbook v2.15 / engine v0.23. Option engine_value\n         strings must match modDropdowns.bas verbatim.
\.


--
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.role (id, code, name, description) FROM stdin;
1	admin	Administrator	Full access within client scope
2	executive	Executive	Read + rollup across assigned org scope
3	capture_manager	Capture Manager	Create/edit pursuits within scope
4	read_only	Read Only	View only
\.


--
-- Data for Name: user_scope_assignment; Type: TABLE DATA; Schema: public; Owner: cpde
--

COPY public.user_scope_assignment (id, user_id, org_node_id, role_id, granted_at, granted_by, client_id) FROM stdin;
\.


--
-- Name: audit_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.audit_log_id_seq', 1, false);


--
-- Name: contract_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.contract_type_id_seq', 3, true);


--
-- Name: labor_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.labor_category_id_seq', 18, true);


--
-- Name: opportunity_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.opportunity_type_id_seq', 4, true);


--
-- Name: phase_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.phase_id_seq', 5, true);


--
-- Name: pipeline_stage_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.pipeline_stage_id_seq', 3, true);


--
-- Name: role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: cpde
--

SELECT pg_catalog.setval('public.role_id_seq', 4, true);


--
-- Name: app_user app_user_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: client client_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_code_key UNIQUE (code);


--
-- Name: client client_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_pkey PRIMARY KEY (id);


--
-- Name: contract_type contract_type_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.contract_type
    ADD CONSTRAINT contract_type_code_key UNIQUE (code);


--
-- Name: contract_type contract_type_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.contract_type
    ADD CONSTRAINT contract_type_pkey PRIMARY KEY (id);


--
-- Name: labor_category labor_category_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.labor_category
    ADD CONSTRAINT labor_category_code_key UNIQUE (code);


--
-- Name: labor_category labor_category_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.labor_category
    ADD CONSTRAINT labor_category_pkey PRIMARY KEY (id);


--
-- Name: market market_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.market
    ADD CONSTRAINT market_pkey PRIMARY KEY (id);


--
-- Name: opportunity_type opportunity_type_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.opportunity_type
    ADD CONSTRAINT opportunity_type_code_key UNIQUE (code);


--
-- Name: opportunity_type opportunity_type_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.opportunity_type
    ADD CONSTRAINT opportunity_type_pkey PRIMARY KEY (id);


--
-- Name: org_node org_node_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.org_node
    ADD CONSTRAINT org_node_pkey PRIMARY KEY (id);


--
-- Name: phase phase_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.phase
    ADD CONSTRAINT phase_code_key UNIQUE (code);


--
-- Name: phase phase_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.phase
    ADD CONSTRAINT phase_pkey PRIMARY KEY (id);


--
-- Name: phase phase_sequence_no_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.phase
    ADD CONSTRAINT phase_sequence_no_key UNIQUE (sequence_no);


--
-- Name: pipeline_stage pipeline_stage_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pipeline_stage
    ADD CONSTRAINT pipeline_stage_code_key UNIQUE (code);


--
-- Name: pipeline_stage pipeline_stage_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pipeline_stage
    ADD CONSTRAINT pipeline_stage_pkey PRIMARY KEY (id);


--
-- Name: pipeline_stage pipeline_stage_sequence_no_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pipeline_stage
    ADD CONSTRAINT pipeline_stage_sequence_no_key UNIQUE (sequence_no);


--
-- Name: plan_year plan_year_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.plan_year
    ADD CONSTRAINT plan_year_pkey PRIMARY KEY (id);


--
-- Name: pursuit_phase_duration pursuit_phase_duration_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_phase_duration
    ADD CONSTRAINT pursuit_phase_duration_pkey PRIMARY KEY (id);


--
-- Name: pursuit pursuit_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_pkey PRIMARY KEY (id);


--
-- Name: pursuit_staffing_meta pursuit_staffing_meta_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing_meta
    ADD CONSTRAINT pursuit_staffing_meta_pkey PRIMARY KEY (pursuit_id);


--
-- Name: pursuit_staffing pursuit_staffing_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing
    ADD CONSTRAINT pursuit_staffing_pkey PRIMARY KEY (id);


--
-- Name: pursuit_year_projection pursuit_year_projection_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_year_projection
    ADD CONSTRAINT pursuit_year_projection_pkey PRIMARY KEY (id);


--
-- Name: pwin_answer pwin_answer_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_answer
    ADD CONSTRAINT pwin_answer_pkey PRIMARY KEY (id);


--
-- Name: pwin_assessment pwin_assessment_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_assessment
    ADD CONSTRAINT pwin_assessment_pkey PRIMARY KEY (id);


--
-- Name: question_dependency question_dependency_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_dependency
    ADD CONSTRAINT question_dependency_pkey PRIMARY KEY (id);


--
-- Name: question_option question_option_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_option
    ADD CONSTRAINT question_option_pkey PRIMARY KEY (id);


--
-- Name: question question_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question
    ADD CONSTRAINT question_pkey PRIMARY KEY (id);


--
-- Name: question_prompt_variant question_prompt_variant_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_prompt_variant
    ADD CONSTRAINT question_prompt_variant_pkey PRIMARY KEY (id);


--
-- Name: questionnaire_version questionnaire_version_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.questionnaire_version
    ADD CONSTRAINT questionnaire_version_pkey PRIMARY KEY (id);


--
-- Name: role role_code_key; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_code_key UNIQUE (code);


--
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (id);


--
-- Name: app_user uq_app_user_email; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT uq_app_user_email UNIQUE (client_id, email);


--
-- Name: market uq_market_code; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.market
    ADD CONSTRAINT uq_market_code UNIQUE (client_id, code);


--
-- Name: org_node uq_org_node_code; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.org_node
    ADD CONSTRAINT uq_org_node_code UNIQUE (client_id, code);


--
-- Name: plan_year uq_plan_year; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.plan_year
    ADD CONSTRAINT uq_plan_year UNIQUE (org_node_id, calendar_year);


--
-- Name: pursuit_phase_duration uq_pursuit_phase; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_phase_duration
    ADD CONSTRAINT uq_pursuit_phase UNIQUE (pursuit_id, phase_id);


--
-- Name: pursuit_staffing uq_pursuit_staffing; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing
    ADD CONSTRAINT uq_pursuit_staffing UNIQUE (pursuit_id, labor_category_id, phase_id);


--
-- Name: pursuit_year_projection uq_pursuit_year; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_year_projection
    ADD CONSTRAINT uq_pursuit_year UNIQUE (pursuit_id, year_offset);


--
-- Name: pwin_answer uq_pwin_answer; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_answer
    ADD CONSTRAINT uq_pwin_answer UNIQUE (pwin_assessment_id, question_id);


--
-- Name: question uq_question; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question
    ADD CONSTRAINT uq_question UNIQUE (questionnaire_version_id, code);


--
-- Name: question_dependency uq_question_dependency; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_dependency
    ADD CONSTRAINT uq_question_dependency UNIQUE (question_id, depends_on_question_id, trigger_option_id);


--
-- Name: question_option uq_question_option; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_option
    ADD CONSTRAINT uq_question_option UNIQUE (question_id, code);


--
-- Name: question_prompt_variant uq_question_prompt_variant; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_prompt_variant
    ADD CONSTRAINT uq_question_prompt_variant UNIQUE (question_id, type_group);


--
-- Name: questionnaire_version uq_qv; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.questionnaire_version
    ADD CONSTRAINT uq_qv UNIQUE (code, version_no);


--
-- Name: user_scope_assignment uq_user_scope; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.user_scope_assignment
    ADD CONSTRAINT uq_user_scope UNIQUE (user_id, org_node_id, role_id);


--
-- Name: user_scope_assignment user_scope_assignment_pkey; Type: CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.user_scope_assignment
    ADD CONSTRAINT user_scope_assignment_pkey PRIMARY KEY (id);


--
-- Name: ix_audit_occurred; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_audit_occurred ON public.audit_log USING btree (occurred_at DESC);


--
-- Name: ix_audit_record; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_audit_record ON public.audit_log USING btree (table_name, record_id);


--
-- Name: ix_audit_user; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_audit_user ON public.audit_log USING btree (user_id, occurred_at DESC);


--
-- Name: ix_org_node_client; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_org_node_client ON public.org_node USING btree (client_id);


--
-- Name: ix_org_node_parent; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_org_node_parent ON public.org_node USING btree (parent_id);


--
-- Name: ix_ppd_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_ppd_cid ON public.pursuit_phase_duration USING btree (client_id);


--
-- Name: ix_pursuit_dep; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pursuit_dep ON public.pursuit USING btree (depends_on_pursuit_id);


--
-- Name: ix_pursuit_market; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pursuit_market ON public.pursuit USING btree (market_id);


--
-- Name: ix_pursuit_open; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pursuit_open ON public.pursuit USING btree (client_id) WHERE ((outcome IS NULL) AND is_active);


--
-- Name: ix_pursuit_org; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pursuit_org ON public.pursuit USING btree (org_node_id);


--
-- Name: ix_pwa_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pwa_cid ON public.pwin_assessment USING btree (client_id);


--
-- Name: ix_pwan_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pwan_cid ON public.pwin_answer USING btree (client_id);


--
-- Name: ix_pwin_answer_assessment; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pwin_answer_assessment ON public.pwin_answer USING btree (pwin_assessment_id);


--
-- Name: ix_pwin_pursuit; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pwin_pursuit ON public.pwin_assessment USING btree (pursuit_id, calculated_at DESC);


--
-- Name: ix_py_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_py_cid ON public.plan_year USING btree (client_id);


--
-- Name: ix_pyp_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pyp_cid ON public.pursuit_year_projection USING btree (client_id);


--
-- Name: ix_pyp_pursuit; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_pyp_pursuit ON public.pursuit_year_projection USING btree (pursuit_id);


--
-- Name: ix_staffing_pursuit; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_staffing_pursuit ON public.pursuit_staffing USING btree (pursuit_id);


--
-- Name: ix_stf_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_stf_cid ON public.pursuit_staffing USING btree (client_id);


--
-- Name: ix_usa_cid; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_usa_cid ON public.user_scope_assignment USING btree (client_id);


--
-- Name: ix_user_scope_user; Type: INDEX; Schema: public; Owner: cpde
--

CREATE INDEX ix_user_scope_user ON public.user_scope_assignment USING btree (user_id);


--
-- Name: uq_pursuit_ext_opp; Type: INDEX; Schema: public; Owner: cpde
--

CREATE UNIQUE INDEX uq_pursuit_ext_opp ON public.pursuit USING btree (client_id, external_opportunity_id) WHERE (external_opportunity_id IS NOT NULL);


--
-- Name: uq_pwin_current; Type: INDEX; Schema: public; Owner: cpde
--

CREATE UNIQUE INDEX uq_pwin_current ON public.pwin_assessment USING btree (pursuit_id, scenario) WHERE is_current;


--
-- Name: uq_qv_active; Type: INDEX; Schema: public; Owner: cpde
--

CREATE UNIQUE INDEX uq_qv_active ON public.questionnaire_version USING btree (code) WHERE is_active;


--
-- Name: plan_year trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.plan_year FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_org();


--
-- Name: pursuit_phase_duration trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.pursuit_phase_duration FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_pursuit();


--
-- Name: pursuit_staffing trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.pursuit_staffing FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_pursuit();


--
-- Name: pursuit_staffing_meta trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.pursuit_staffing_meta FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_pursuit();


--
-- Name: pursuit_year_projection trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.pursuit_year_projection FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_pursuit();


--
-- Name: pwin_answer trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.pwin_answer FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_assessment();


--
-- Name: pwin_assessment trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.pwin_assessment FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_pursuit();


--
-- Name: user_scope_assignment trg_cid; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_cid BEFORE INSERT OR UPDATE ON public.user_scope_assignment FOR EACH ROW EXECUTE FUNCTION public.fn_inherit_client_from_user();


--
-- Name: market trg_market_code_immutable; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_market_code_immutable BEFORE UPDATE ON public.market FOR EACH ROW EXECUTE FUNCTION public.fn_market_code_immutable();


--
-- Name: org_node trg_org_node_validate; Type: TRIGGER; Schema: public; Owner: cpde
--

CREATE TRIGGER trg_org_node_validate BEFORE INSERT OR UPDATE ON public.org_node FOR EACH ROW EXECUTE FUNCTION public.fn_org_node_validate();


--
-- Name: app_user app_user_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id) ON DELETE RESTRICT;


--
-- Name: market market_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.market
    ADD CONSTRAINT market_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id) ON DELETE RESTRICT;


--
-- Name: org_node org_node_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.org_node
    ADD CONSTRAINT org_node_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id) ON DELETE RESTRICT;


--
-- Name: org_node org_node_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.org_node
    ADD CONSTRAINT org_node_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.org_node(id) ON DELETE RESTRICT;


--
-- Name: plan_year plan_year_org_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.plan_year
    ADD CONSTRAINT plan_year_org_node_id_fkey FOREIGN KEY (org_node_id) REFERENCES public.org_node(id) ON DELETE CASCADE;


--
-- Name: pursuit pursuit_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id) ON DELETE RESTRICT;


--
-- Name: pursuit pursuit_contract_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_contract_type_id_fkey FOREIGN KEY (contract_type_id) REFERENCES public.contract_type(id);


--
-- Name: pursuit pursuit_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.app_user(id);


--
-- Name: pursuit pursuit_depends_on_pursuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_depends_on_pursuit_id_fkey FOREIGN KEY (depends_on_pursuit_id) REFERENCES public.pursuit(id) ON DELETE SET NULL;


--
-- Name: pursuit pursuit_market_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_market_id_fkey FOREIGN KEY (market_id) REFERENCES public.market(id) ON DELETE RESTRICT;


--
-- Name: pursuit pursuit_opportunity_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_opportunity_type_id_fkey FOREIGN KEY (opportunity_type_id) REFERENCES public.opportunity_type(id);


--
-- Name: pursuit pursuit_org_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_org_node_id_fkey FOREIGN KEY (org_node_id) REFERENCES public.org_node(id) ON DELETE RESTRICT;


--
-- Name: pursuit_phase_duration pursuit_phase_duration_phase_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_phase_duration
    ADD CONSTRAINT pursuit_phase_duration_phase_id_fkey FOREIGN KEY (phase_id) REFERENCES public.phase(id);


--
-- Name: pursuit_phase_duration pursuit_phase_duration_pursuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_phase_duration
    ADD CONSTRAINT pursuit_phase_duration_pursuit_id_fkey FOREIGN KEY (pursuit_id) REFERENCES public.pursuit(id) ON DELETE CASCADE;


--
-- Name: pursuit pursuit_pipeline_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_pipeline_stage_id_fkey FOREIGN KEY (pipeline_stage_id) REFERENCES public.pipeline_stage(id);


--
-- Name: pursuit_staffing pursuit_staffing_labor_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing
    ADD CONSTRAINT pursuit_staffing_labor_category_id_fkey FOREIGN KEY (labor_category_id) REFERENCES public.labor_category(id);


--
-- Name: pursuit_staffing_meta pursuit_staffing_meta_pursuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing_meta
    ADD CONSTRAINT pursuit_staffing_meta_pursuit_id_fkey FOREIGN KEY (pursuit_id) REFERENCES public.pursuit(id) ON DELETE CASCADE;


--
-- Name: pursuit_staffing pursuit_staffing_phase_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing
    ADD CONSTRAINT pursuit_staffing_phase_id_fkey FOREIGN KEY (phase_id) REFERENCES public.phase(id);


--
-- Name: pursuit_staffing pursuit_staffing_pursuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_staffing
    ADD CONSTRAINT pursuit_staffing_pursuit_id_fkey FOREIGN KEY (pursuit_id) REFERENCES public.pursuit(id) ON DELETE CASCADE;


--
-- Name: pursuit pursuit_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit
    ADD CONSTRAINT pursuit_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.app_user(id);


--
-- Name: pursuit_year_projection pursuit_year_projection_pursuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pursuit_year_projection
    ADD CONSTRAINT pursuit_year_projection_pursuit_id_fkey FOREIGN KEY (pursuit_id) REFERENCES public.pursuit(id) ON DELETE CASCADE;


--
-- Name: pwin_answer pwin_answer_pwin_assessment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_answer
    ADD CONSTRAINT pwin_answer_pwin_assessment_id_fkey FOREIGN KEY (pwin_assessment_id) REFERENCES public.pwin_assessment(id) ON DELETE CASCADE;


--
-- Name: pwin_answer pwin_answer_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_answer
    ADD CONSTRAINT pwin_answer_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.question(id);


--
-- Name: pwin_answer pwin_answer_question_option_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_answer
    ADD CONSTRAINT pwin_answer_question_option_id_fkey FOREIGN KEY (question_option_id) REFERENCES public.question_option(id);


--
-- Name: pwin_assessment pwin_assessment_calculated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_assessment
    ADD CONSTRAINT pwin_assessment_calculated_by_fkey FOREIGN KEY (calculated_by) REFERENCES public.app_user(id);


--
-- Name: pwin_assessment pwin_assessment_pursuit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_assessment
    ADD CONSTRAINT pwin_assessment_pursuit_id_fkey FOREIGN KEY (pursuit_id) REFERENCES public.pursuit(id) ON DELETE CASCADE;


--
-- Name: pwin_assessment pwin_assessment_questionnaire_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.pwin_assessment
    ADD CONSTRAINT pwin_assessment_questionnaire_version_id_fkey FOREIGN KEY (questionnaire_version_id) REFERENCES public.questionnaire_version(id);


--
-- Name: question_dependency question_dependency_depends_on_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_dependency
    ADD CONSTRAINT question_dependency_depends_on_question_id_fkey FOREIGN KEY (depends_on_question_id) REFERENCES public.question(id) ON DELETE CASCADE;


--
-- Name: question_dependency question_dependency_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_dependency
    ADD CONSTRAINT question_dependency_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.question(id) ON DELETE CASCADE;


--
-- Name: question_dependency question_dependency_trigger_option_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_dependency
    ADD CONSTRAINT question_dependency_trigger_option_id_fkey FOREIGN KEY (trigger_option_id) REFERENCES public.question_option(id) ON DELETE CASCADE;


--
-- Name: question_option question_option_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_option
    ADD CONSTRAINT question_option_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.question(id) ON DELETE CASCADE;


--
-- Name: question_prompt_variant question_prompt_variant_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question_prompt_variant
    ADD CONSTRAINT question_prompt_variant_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.question(id) ON DELETE CASCADE;


--
-- Name: question question_questionnaire_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.question
    ADD CONSTRAINT question_questionnaire_version_id_fkey FOREIGN KEY (questionnaire_version_id) REFERENCES public.questionnaire_version(id) ON DELETE CASCADE;


--
-- Name: user_scope_assignment user_scope_assignment_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.user_scope_assignment
    ADD CONSTRAINT user_scope_assignment_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES public.app_user(id);


--
-- Name: user_scope_assignment user_scope_assignment_org_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.user_scope_assignment
    ADD CONSTRAINT user_scope_assignment_org_node_id_fkey FOREIGN KEY (org_node_id) REFERENCES public.org_node(id) ON DELETE CASCADE;


--
-- Name: user_scope_assignment user_scope_assignment_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.user_scope_assignment
    ADD CONSTRAINT user_scope_assignment_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(id);


--
-- Name: user_scope_assignment user_scope_assignment_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: cpde
--

ALTER TABLE ONLY public.user_scope_assignment
    ADD CONSTRAINT user_scope_assignment_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_user(id) ON DELETE CASCADE;


--
-- Name: app_user; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.app_user ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: client; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.client ENABLE ROW LEVEL SECURITY;

--
-- Name: market; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.market ENABLE ROW LEVEL SECURITY;

--
-- Name: org_node; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.org_node ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_year; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.plan_year ENABLE ROW LEVEL SECURITY;

--
-- Name: pursuit; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pursuit ENABLE ROW LEVEL SECURITY;

--
-- Name: pursuit_phase_duration; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pursuit_phase_duration ENABLE ROW LEVEL SECURITY;

--
-- Name: pursuit_staffing; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pursuit_staffing ENABLE ROW LEVEL SECURITY;

--
-- Name: pursuit_staffing_meta; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pursuit_staffing_meta ENABLE ROW LEVEL SECURITY;

--
-- Name: pursuit_year_projection; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pursuit_year_projection ENABLE ROW LEVEL SECURITY;

--
-- Name: pwin_answer; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pwin_answer ENABLE ROW LEVEL SECURITY;

--
-- Name: pwin_assessment; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.pwin_assessment ENABLE ROW LEVEL SECURITY;

--
-- Name: app_user tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.app_user USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: audit_log tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.audit_log USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: client tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.client USING ((id = public.current_tenant())) WITH CHECK ((id = public.current_tenant()));


--
-- Name: market tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.market USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: org_node tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.org_node USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: plan_year tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.plan_year USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pursuit tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pursuit USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pursuit_phase_duration tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pursuit_phase_duration USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pursuit_staffing tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pursuit_staffing USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pursuit_staffing_meta tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pursuit_staffing_meta USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pursuit_year_projection tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pursuit_year_projection USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pwin_answer tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pwin_answer USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: pwin_assessment tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.pwin_assessment USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: user_scope_assignment tenant_isolation; Type: POLICY; Schema: public; Owner: cpde
--

CREATE POLICY tenant_isolation ON public.user_scope_assignment USING ((client_id = public.current_tenant())) WITH CHECK ((client_id = public.current_tenant()));


--
-- Name: user_scope_assignment; Type: ROW SECURITY; Schema: public; Owner: cpde
--

ALTER TABLE public.user_scope_assignment ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO cpde_app;


--
-- Name: TABLE app_user; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.app_user TO cpde_app;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.audit_log TO cpde_app;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.audit_log_id_seq TO cpde_app;


--
-- Name: TABLE client; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.client TO cpde_app;


--
-- Name: TABLE contract_type; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contract_type TO cpde_app;


--
-- Name: SEQUENCE contract_type_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.contract_type_id_seq TO cpde_app;


--
-- Name: TABLE labor_category; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.labor_category TO cpde_app;


--
-- Name: SEQUENCE labor_category_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.labor_category_id_seq TO cpde_app;


--
-- Name: TABLE market; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.market TO cpde_app;


--
-- Name: TABLE opportunity_type; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.opportunity_type TO cpde_app;


--
-- Name: SEQUENCE opportunity_type_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.opportunity_type_id_seq TO cpde_app;


--
-- Name: TABLE org_node; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.org_node TO cpde_app;


--
-- Name: TABLE phase; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.phase TO cpde_app;


--
-- Name: SEQUENCE phase_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.phase_id_seq TO cpde_app;


--
-- Name: TABLE pipeline_stage; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pipeline_stage TO cpde_app;


--
-- Name: SEQUENCE pipeline_stage_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.pipeline_stage_id_seq TO cpde_app;


--
-- Name: TABLE plan_year; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.plan_year TO cpde_app;


--
-- Name: TABLE pursuit; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pursuit TO cpde_app;


--
-- Name: TABLE pursuit_phase_duration; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pursuit_phase_duration TO cpde_app;


--
-- Name: TABLE pursuit_staffing; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pursuit_staffing TO cpde_app;


--
-- Name: TABLE pursuit_staffing_meta; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pursuit_staffing_meta TO cpde_app;


--
-- Name: TABLE pursuit_year_projection; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pursuit_year_projection TO cpde_app;


--
-- Name: TABLE pwin_answer; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pwin_answer TO cpde_app;


--
-- Name: TABLE pwin_assessment; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pwin_assessment TO cpde_app;


--
-- Name: TABLE question; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.question TO cpde_app;


--
-- Name: TABLE question_dependency; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.question_dependency TO cpde_app;


--
-- Name: TABLE question_option; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.question_option TO cpde_app;


--
-- Name: TABLE question_prompt_variant; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.question_prompt_variant TO cpde_app;


--
-- Name: TABLE questionnaire_version; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.questionnaire_version TO cpde_app;


--
-- Name: TABLE role; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role TO cpde_app;


--
-- Name: SEQUENCE role_id_seq; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,USAGE ON SEQUENCE public.role_id_seq TO cpde_app;


--
-- Name: TABLE user_scope_assignment; Type: ACL; Schema: public; Owner: cpde
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_scope_assignment TO cpde_app;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: cpde
--

ALTER DEFAULT PRIVILEGES FOR ROLE cpde IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO cpde_app;


--
-- PostgreSQL database dump complete
--

\unrestrict xFF1uuNeyHIgYQG0VqNYzGxHumKGxFUetdHNLExYjlLLtyfBb55LDM5AlST6cBK

