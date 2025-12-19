--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4 (Postgres.app)
-- Dumped by pg_dump version 17.5 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: postgres
--

-- *not* creating schema, since initdb creates it


ALTER SCHEMA public OWNER TO postgres;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA public IS '';


--
-- Name: clean_expired_verification_codes(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.clean_expired_verification_codes() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM verification_codes WHERE expires_at < CURRENT_TIMESTAMP;
END;
$$;


ALTER FUNCTION public.clean_expired_verification_codes() OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_versions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.app_versions (
    id integer NOT NULL,
    version character varying(50) NOT NULL,
    platform character varying(20) NOT NULL,
    distribution_type character varying(20) DEFAULT 'oss'::character varying,
    package_url text,
    oss_object_key character varying(500),
    release_notes text,
    status character varying(20) DEFAULT 'draft'::character varying,
    is_force_update boolean DEFAULT false,
    min_supported_version character varying(50),
    file_size bigint DEFAULT 0,
    file_hash character varying(128),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    published_at timestamp with time zone,
    created_by character varying(100)
);


ALTER TABLE public.app_versions OWNER TO postgres;

--
-- Name: TABLE app_versions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.app_versions IS 'Application version upgrade information table';


--
-- Name: COLUMN app_versions.version; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.version IS 'Version number';


--
-- Name: COLUMN app_versions.platform; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.platform IS 'Platform: windows, android, ios';


--
-- Name: COLUMN app_versions.distribution_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.distribution_type IS 'Distribution type: oss(OSS file), url(external link like TestFlight)';


--
-- Name: COLUMN app_versions.package_url; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.package_url IS 'Upgrade package download address/distribution address';


--
-- Name: COLUMN app_versions.oss_object_key; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.oss_object_key IS 'OSS object storage key (only for oss type)';


--
-- Name: COLUMN app_versions.release_notes; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.release_notes IS 'Upgrade description information';


--
-- Name: COLUMN app_versions.status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.status IS 'Status: draft, published, deprecated';


--
-- Name: COLUMN app_versions.is_force_update; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.is_force_update IS 'Whether to force update';


--
-- Name: COLUMN app_versions.min_supported_version; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.min_supported_version IS 'Minimum supported version';


--
-- Name: COLUMN app_versions.file_size; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.file_size IS 'File size (bytes, only for oss type)';


--
-- Name: COLUMN app_versions.file_hash; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.app_versions.file_hash IS 'File hash value (only for oss type)';


--
-- Name: app_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.app_versions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.app_versions_id_seq OWNER TO postgres;

--
-- Name: app_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.app_versions_id_seq OWNED BY public.app_versions.id;


--
-- Name: device_registrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.device_registrations (
    id integer NOT NULL,
    uuid character varying(255) NOT NULL,
    request_ip character varying(50) NOT NULL,
    platform character varying(20) NOT NULL,
    system_info jsonb NOT NULL,
    installed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.device_registrations OWNER TO postgres;

--
-- Name: TABLE device_registrations; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.device_registrations IS 'Device registration table: records device information on first app startup';


--
-- Name: COLUMN device_registrations.uuid; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.device_registrations.uuid IS 'Database encryption key UUID (original UUID, not MD5 encrypted)';


--
-- Name: COLUMN device_registrations.request_ip; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.device_registrations.request_ip IS 'Client request IP address';


--
-- Name: COLUMN device_registrations.platform; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.device_registrations.platform IS 'Operating system platform: android, ios, windows, macos, linux';


--
-- Name: COLUMN device_registrations.system_info; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.device_registrations.system_info IS 'System detailed information in JSON format, includes device model, OS version, etc';


--
-- Name: COLUMN device_registrations.installed_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.device_registrations.installed_at IS 'Application first installation/startup time';


--
-- Name: device_registrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.device_registrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.device_registrations_id_seq OWNER TO postgres;

--
-- Name: device_registrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.device_registrations_id_seq OWNED BY public.device_registrations.id;


--
-- Name: favorite_contacts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.favorite_contacts (
    id integer NOT NULL,
    user_id integer NOT NULL,
    contact_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.favorite_contacts OWNER TO postgres;

--
-- Name: TABLE favorite_contacts; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.favorite_contacts IS 'Favorite Contacts Table';


--
-- Name: COLUMN favorite_contacts.user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorite_contacts.user_id IS 'User ID';


--
-- Name: COLUMN favorite_contacts.contact_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorite_contacts.contact_id IS 'Favorite contact ID';


--
-- Name: COLUMN favorite_contacts.created_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorite_contacts.created_at IS 'Created at';


--
-- Name: favorite_contacts_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.favorite_contacts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.favorite_contacts_id_seq OWNER TO postgres;

--
-- Name: favorite_contacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.favorite_contacts_id_seq OWNED BY public.favorite_contacts.id;


--
-- Name: favorite_groups; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.favorite_groups (
    id integer NOT NULL,
    user_id integer NOT NULL,
    group_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.favorite_groups OWNER TO postgres;

--
-- Name: TABLE favorite_groups; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.favorite_groups IS 'Favorite Groups Table';


--
-- Name: COLUMN favorite_groups.user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorite_groups.user_id IS 'User ID';


--
-- Name: COLUMN favorite_groups.group_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorite_groups.group_id IS 'Favorite group ID';


--
-- Name: COLUMN favorite_groups.created_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorite_groups.created_at IS 'Created at';


--
-- Name: favorite_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.favorite_groups_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.favorite_groups_id_seq OWNER TO postgres;

--
-- Name: favorite_groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.favorite_groups_id_seq OWNED BY public.favorite_groups.id;


--
-- Name: favorites; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.favorites (
    id integer NOT NULL,
    user_id integer NOT NULL,
    message_id integer,
    content text NOT NULL,
    message_type character varying(20) DEFAULT 'text'::character varying,
    file_name character varying(255),
    sender_id integer NOT NULL,
    sender_name character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    server_id integer,
    sync_status character varying(20) DEFAULT 'synced'::character varying
);


ALTER TABLE public.favorites OWNER TO postgres;

--
-- Name: TABLE favorites; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.favorites IS 'User Favorite Messages Table';


--
-- Name: COLUMN favorites.user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.user_id IS 'User ID who favorited this message';


--
-- Name: COLUMN favorites.message_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.message_id IS 'Favorited message ID (nullable if original message is deleted)';


--
-- Name: COLUMN favorites.content; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.content IS 'Message content';


--
-- Name: COLUMN favorites.message_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.message_type IS 'Message type: text, image, file, quoted';


--
-- Name: COLUMN favorites.file_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.file_name IS 'File name (for file type)';


--
-- Name: COLUMN favorites.sender_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.sender_id IS 'Original message sender ID';


--
-- Name: COLUMN favorites.sender_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.sender_name IS 'Original message sender name';


--
-- Name: COLUMN favorites.created_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.favorites.created_at IS 'Favorited at';


--
-- Name: favorites_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.favorites_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.favorites_id_seq OWNER TO postgres;

--
-- Name: favorites_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.favorites_id_seq OWNED BY public.favorites.id;


--
-- Name: file_assistant_messages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.file_assistant_messages (
    id integer NOT NULL,
    user_id integer NOT NULL,
    content text NOT NULL,
    message_type character varying(20) DEFAULT 'text'::character varying,
    file_name character varying(255),
    quoted_message_id integer,
    quoted_message_content text,
    status character varying(20) DEFAULT 'normal'::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    server_id integer
);


ALTER TABLE public.file_assistant_messages OWNER TO postgres;

--
-- Name: TABLE file_assistant_messages; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.file_assistant_messages IS 'File Assistant Messages Table';


--
-- Name: COLUMN file_assistant_messages.user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.user_id IS 'User ID';


--
-- Name: COLUMN file_assistant_messages.content; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.content IS 'Message content';


--
-- Name: COLUMN file_assistant_messages.message_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.message_type IS 'Message type: text, image, file, quoted';


--
-- Name: COLUMN file_assistant_messages.file_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.file_name IS 'File name (for file type)';


--
-- Name: COLUMN file_assistant_messages.quoted_message_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.quoted_message_id IS 'Quoted message ID';


--
-- Name: COLUMN file_assistant_messages.quoted_message_content; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.quoted_message_content IS 'Quoted message content';


--
-- Name: COLUMN file_assistant_messages.status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.status IS 'Message status: normal, recalled';


--
-- Name: COLUMN file_assistant_messages.created_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.file_assistant_messages.created_at IS 'Created at';


--
-- Name: file_assistant_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.file_assistant_messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.file_assistant_messages_id_seq OWNER TO postgres;

--
-- Name: file_assistant_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.file_assistant_messages_id_seq OWNED BY public.file_assistant_messages.id;


--
-- Name: group_members; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.group_members (
    id integer NOT NULL,
    group_id integer NOT NULL,
    user_id integer NOT NULL,
    nickname character varying(100),
    remark character varying(255),
    role character varying(20) DEFAULT 'member'::character varying,
    joined_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    is_muted boolean DEFAULT false,
    approval_status character varying(20) DEFAULT 'approved'::character varying,
    do_not_disturb boolean DEFAULT false,
    CONSTRAINT check_approval_status CHECK (((approval_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('approved'::character varying)::text, ('rejected'::character varying)::text])))
);


ALTER TABLE public.group_members OWNER TO postgres;

--
-- Name: COLUMN group_members.is_muted; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_members.is_muted IS 'Whether the member is muted';


--
-- Name: COLUMN group_members.approval_status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_members.approval_status IS 'Approval status: pending, approved, rejected';


--
-- Name: COLUMN group_members.do_not_disturb; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_members.do_not_disturb IS 'Do not disturb: true displays only a red dot, false displays unread message count';


--
-- Name: group_members_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.group_members_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.group_members_id_seq OWNER TO postgres;

--
-- Name: group_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.group_members_id_seq OWNED BY public.group_members.id;


--
-- Name: group_message_reads; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.group_message_reads (
    id integer NOT NULL,
    group_message_id integer NOT NULL,
    user_id integer NOT NULL,
    read_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.group_message_reads OWNER TO postgres;

--
-- Name: group_message_reads_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.group_message_reads_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.group_message_reads_id_seq OWNER TO postgres;

--
-- Name: group_message_reads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.group_message_reads_id_seq OWNED BY public.group_message_reads.id;


--
-- Name: group_messages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.group_messages (
    id integer NOT NULL,
    group_id integer NOT NULL,
    sender_id integer,
    sender_name character varying(100) NOT NULL,
    content text NOT NULL,
    message_type character varying(20) DEFAULT 'text'::character varying,
    file_name character varying(255),
    quoted_message_id integer,
    quoted_message_content text,
    status character varying(20) DEFAULT 'normal'::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sender_avatar text,
    mentioned_user_ids text,
    mentions text,
    deleted_by_users text DEFAULT ''::text,
    call_type character varying(20),
    channel_name character varying(255),
    sender_nickname character varying(100),
    sender_full_name character varying(100),
    server_id integer,
    voice_duration integer
);


ALTER TABLE public.group_messages OWNER TO postgres;

--
-- Name: COLUMN group_messages.sender_avatar; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.sender_avatar IS 'Sender avatar URL';


--
-- Name: COLUMN group_messages.mentioned_user_ids; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.mentioned_user_ids IS 'List of mentioned user IDs (comma-separated string)';


--
-- Name: COLUMN group_messages.mentions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.mentions IS 'Mention text content (e.g., "@all" or "@username")';


--
-- Name: COLUMN group_messages.deleted_by_users; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.deleted_by_users IS 'Comma-separated list of user IDs who have deleted this message';


--
-- Name: COLUMN group_messages.call_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.call_type IS 'Call type (voice/video), only used for call_initiated type messages';


--
-- Name: COLUMN group_messages.channel_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.channel_name IS 'Agora channel name, used to join group calls, only used for call_initiated type messages';


--
-- Name: COLUMN group_messages.sender_nickname; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.sender_nickname IS 'Sender group nickname (from group_members.nickname)';


--
-- Name: COLUMN group_messages.sender_full_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.sender_full_name IS 'Sender full name (from users.full_name)';


--
-- Name: COLUMN group_messages.voice_duration; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.group_messages.voice_duration IS 'Voice message duration (seconds)';


--
-- Name: group_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.group_messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.group_messages_id_seq OWNER TO postgres;

--
-- Name: group_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.group_messages_id_seq OWNED BY public.group_messages.id;


--
-- Name: groups; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.groups (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    announcement text,
    avatar character varying(255),
    owner_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp without time zone,
    all_muted boolean DEFAULT false NOT NULL,
    invite_confirmation boolean DEFAULT false,
    admin_only_edit_name boolean DEFAULT false NOT NULL,
    member_view_permission boolean DEFAULT true
);


ALTER TABLE public.groups OWNER TO postgres;

--
-- Name: COLUMN groups.deleted_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.groups.deleted_at IS 'Soft delete timestamp (NULL means not deleted)';


--
-- Name: COLUMN groups.all_muted; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.groups.all_muted IS 'Whether all members are muted';


--
-- Name: COLUMN groups.invite_confirmation; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.groups.invite_confirmation IS 'Enable group invite confirmation (member invitations require approval)';


--
-- Name: COLUMN groups.admin_only_edit_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.groups.admin_only_edit_name IS 'Whether only the group owner/admins can modify the group name';


--
-- Name: COLUMN groups.member_view_permission; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.groups.member_view_permission IS 'Member view permission: true = regular members can view other members'' information, false = only the owner and administrators can view member information.';


--
-- Name: groups_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.groups_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.groups_id_seq OWNER TO postgres;

--
-- Name: groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.groups_id_seq OWNED BY public.groups.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.messages (
    id integer NOT NULL,
    sender_id integer NOT NULL,
    receiver_id integer NOT NULL,
    content text NOT NULL,
    message_type character varying(20) DEFAULT 'text'::character varying,
    is_read boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    read_at timestamp without time zone,
    sender_name character varying(100),
    receiver_name character varying(100),
    file_name character varying(255) DEFAULT NULL::character varying,
    quoted_message_id integer,
    quoted_message_content text,
    status character varying(20) DEFAULT 'normal'::character varying,
    deleted_by_users text DEFAULT ''::text,
    sender_avatar text,
    receiver_avatar text,
    call_type character varying(20) DEFAULT NULL::character varying,
    server_id integer,
    voice_duration integer
);


ALTER TABLE public.messages OWNER TO postgres;

--
-- Name: COLUMN messages.sender_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.sender_name IS 'Sender username';


--
-- Name: COLUMN messages.receiver_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.receiver_name IS 'Receiver username';


--
-- Name: COLUMN messages.file_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.file_name IS 'File name (for file type messages)';


--
-- Name: COLUMN messages.quoted_message_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.quoted_message_id IS 'Quoted message ID';


--
-- Name: COLUMN messages.quoted_message_content; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.quoted_message_content IS 'Quoted message content (for display)';


--
-- Name: COLUMN messages.status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.status IS 'Message status: normal, recalled';


--
-- Name: COLUMN messages.deleted_by_users; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.deleted_by_users IS 'List of user IDs who deleted this message (comma-separated), e.g., 1,2,3';


--
-- Name: COLUMN messages.sender_avatar; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.sender_avatar IS 'Sender avatar URL';


--
-- Name: COLUMN messages.receiver_avatar; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.receiver_avatar IS 'Receiver avatar URL';


--
-- Name: COLUMN messages.call_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.call_type IS 'Call type (voice/video), used only for call message types';


--
-- Name: COLUMN messages.voice_duration; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.messages.voice_duration IS 'Voice message duration (seconds)';


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.messages_id_seq OWNER TO postgres;

--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: private_message_synced; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.private_message_synced (
    id integer NOT NULL,
    message_id integer NOT NULL,
    user_id integer NOT NULL,
    synced_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.private_message_synced OWNER TO postgres;

--
-- Name: private_message_synced_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.private_message_synced_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.private_message_synced_id_seq OWNER TO postgres;

--
-- Name: private_message_synced_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.private_message_synced_id_seq OWNED BY public.private_message_synced.id;


--
-- Name: server_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.server_settings (
    id integer NOT NULL,
    key character varying(100) NOT NULL,
    value text NOT NULL,
    description character varying(255) DEFAULT ''::character varying,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.server_settings OWNER TO postgres;

--
-- Name: TABLE server_settings; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.server_settings IS 'Server Settings Table';


--
-- Name: server_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.server_settings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.server_settings_id_seq OWNER TO postgres;

--
-- Name: server_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.server_settings_id_seq OWNED BY public.server_settings.id;


--
-- Name: user_relations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_relations (
    id integer NOT NULL,
    user_id integer NOT NULL,
    friend_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    approval_status character varying(20) DEFAULT 'approved'::character varying NOT NULL,
    is_blocked boolean DEFAULT false NOT NULL,
    is_deleted boolean DEFAULT false NOT NULL,
    blocked_by_user_id integer,
    deleted_by_user_id integer,
    CONSTRAINT check_approval_status CHECK (((approval_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('approved'::character varying)::text, ('rejected'::character varying)::text])))
);


ALTER TABLE public.user_relations OWNER TO postgres;

--
-- Name: TABLE user_relations; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.user_relations IS 'User Relations Table';


--
-- Name: COLUMN user_relations.user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.user_id IS 'User ID';


--
-- Name: COLUMN user_relations.friend_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.friend_id IS 'Friend user ID';


--
-- Name: COLUMN user_relations.created_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.created_at IS 'Created at';


--
-- Name: COLUMN user_relations.approval_status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.approval_status IS 'Approval status: pending, approved, rejected';


--
-- Name: COLUMN user_relations.is_blocked; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.is_blocked IS 'Whether the user is blocked; true means blocked';


--
-- Name: COLUMN user_relations.is_deleted; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.is_deleted IS 'Whether the relation is deleted (soft delete); true means deleted';


--
-- Name: COLUMN user_relations.blocked_by_user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.blocked_by_user_id IS 'User ID who performed the block operation';


--
-- Name: COLUMN user_relations.deleted_by_user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.user_relations.deleted_by_user_id IS 'User ID who performed the delete operation';


--
-- Name: user_relations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.user_relations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.user_relations_id_seq OWNER TO postgres;

--
-- Name: user_relations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.user_relations_id_seq OWNED BY public.user_relations.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id integer NOT NULL,
    username character varying(50) NOT NULL,
    password character varying(255) NOT NULL,
    phone character varying(20) DEFAULT NULL::character varying,
    email character varying(100) DEFAULT NULL::character varying,
    avatar character varying(255) DEFAULT ''::character varying,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    auth_code character varying(100) DEFAULT NULL::character varying,
    full_name character varying(100) DEFAULT NULL::character varying,
    gender character varying(10) DEFAULT NULL::character varying,
    work_signature character varying(500) DEFAULT NULL::character varying,
    status character varying(50) DEFAULT 'offline'::character varying,
    landline character varying(20) DEFAULT NULL::character varying,
    short_number character varying(10) DEFAULT NULL::character varying,
    department character varying(100) DEFAULT NULL::character varying,
    "position" character varying(100) DEFAULT NULL::character varying,
    region character varying(100) DEFAULT NULL::character varying,
    invite_code character varying(6) DEFAULT NULL::character varying,
    invited_by_code character varying(6) DEFAULT NULL::character varying,
    CONSTRAINT check_gender CHECK (((gender)::text = ANY (ARRAY[(NULL::character varying)::text, ('male'::character varying)::text, ('female'::character varying)::text, ('other'::character varying)::text]))),
    CONSTRAINT check_status CHECK (((status)::text = ANY (ARRAY[('online'::character varying)::text, ('busy'::character varying)::text, ('away'::character varying)::text, ('offline'::character varying)::text])))
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.users IS 'Users Table';


--
-- Name: COLUMN users.auth_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.auth_code IS 'Authorization code';


--
-- Name: COLUMN users.full_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.full_name IS 'Full name';


--
-- Name: COLUMN users.gender; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.gender IS 'Gender: male, female, other';


--
-- Name: COLUMN users.work_signature; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.work_signature IS 'Work signature';


--
-- Name: COLUMN users.status; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.status IS 'Status: online, busy, away, offline';


--
-- Name: COLUMN users.landline; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.landline IS 'Landline';


--
-- Name: COLUMN users.short_number; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.short_number IS 'Short number';


--
-- Name: COLUMN users.department; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.department IS 'Department';


--
-- Name: COLUMN users."position"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users."position" IS 'Position';


--
-- Name: COLUMN users.region; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.region IS 'Region';


--
-- Name: COLUMN users.invite_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.invite_code IS 'User''s own invite code (6 characters, 0-9a-zA-Z)';


--
-- Name: COLUMN users.invited_by_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.users.invited_by_code IS 'Invite code used during registration';


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq OWNER TO postgres;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: verification_codes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.verification_codes (
    id integer NOT NULL,
    account character varying(100) NOT NULL,
    code character varying(10) NOT NULL,
    type character varying(20) NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT verification_codes_type_check CHECK (((type)::text = ANY (ARRAY[('login'::character varying)::text, ('register'::character varying)::text, ('reset'::character varying)::text])))
);


ALTER TABLE public.verification_codes OWNER TO postgres;

--
-- Name: TABLE verification_codes; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.verification_codes IS 'Verification Codes Table';


--
-- Name: verification_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.verification_codes_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.verification_codes_id_seq OWNER TO postgres;

--
-- Name: verification_codes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.verification_codes_id_seq OWNED BY public.verification_codes.id;


--
-- Name: app_versions id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_versions ALTER COLUMN id SET DEFAULT nextval('public.app_versions_id_seq'::regclass);


--
-- Name: device_registrations id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations ALTER COLUMN id SET DEFAULT nextval('public.device_registrations_id_seq'::regclass);


--
-- Name: favorite_contacts id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_contacts ALTER COLUMN id SET DEFAULT nextval('public.favorite_contacts_id_seq'::regclass);


--
-- Name: favorite_groups id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_groups ALTER COLUMN id SET DEFAULT nextval('public.favorite_groups_id_seq'::regclass);


--
-- Name: favorites id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorites ALTER COLUMN id SET DEFAULT nextval('public.favorites_id_seq'::regclass);


--
-- Name: file_assistant_messages id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_assistant_messages ALTER COLUMN id SET DEFAULT nextval('public.file_assistant_messages_id_seq'::regclass);


--
-- Name: group_members id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_members ALTER COLUMN id SET DEFAULT nextval('public.group_members_id_seq'::regclass);


--
-- Name: group_message_reads id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_message_reads ALTER COLUMN id SET DEFAULT nextval('public.group_message_reads_id_seq'::regclass);


--
-- Name: group_messages id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_messages ALTER COLUMN id SET DEFAULT nextval('public.group_messages_id_seq'::regclass);


--
-- Name: groups id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.groups ALTER COLUMN id SET DEFAULT nextval('public.groups_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: private_message_synced id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.private_message_synced ALTER COLUMN id SET DEFAULT nextval('public.private_message_synced_id_seq'::regclass);


--
-- Name: server_settings id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.server_settings ALTER COLUMN id SET DEFAULT nextval('public.server_settings_id_seq'::regclass);


--
-- Name: user_relations id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_relations ALTER COLUMN id SET DEFAULT nextval('public.user_relations_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: verification_codes id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification_codes ALTER COLUMN id SET DEFAULT nextval('public.verification_codes_id_seq'::regclass);


--
-- Name: app_versions app_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_versions
    ADD CONSTRAINT app_versions_pkey PRIMARY KEY (id);


--
-- Name: app_versions app_versions_version_platform_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.app_versions
    ADD CONSTRAINT app_versions_version_platform_key UNIQUE (version, platform);


--
-- Name: device_registrations device_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations
    ADD CONSTRAINT device_registrations_pkey PRIMARY KEY (id);


--
-- Name: device_registrations device_registrations_uuid_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations
    ADD CONSTRAINT device_registrations_uuid_key UNIQUE (uuid);


--
-- Name: favorite_contacts favorite_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_contacts
    ADD CONSTRAINT favorite_contacts_pkey PRIMARY KEY (id);


--
-- Name: favorite_contacts favorite_contacts_user_id_contact_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_contacts
    ADD CONSTRAINT favorite_contacts_user_id_contact_id_key UNIQUE (user_id, contact_id);


--
-- Name: favorite_groups favorite_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_groups
    ADD CONSTRAINT favorite_groups_pkey PRIMARY KEY (id);


--
-- Name: favorite_groups favorite_groups_user_id_group_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_groups
    ADD CONSTRAINT favorite_groups_user_id_group_id_key UNIQUE (user_id, group_id);


--
-- Name: favorites favorites_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT favorites_pkey PRIMARY KEY (id);


--
-- Name: file_assistant_messages file_assistant_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_assistant_messages
    ADD CONSTRAINT file_assistant_messages_pkey PRIMARY KEY (id);


--
-- Name: group_members group_members_group_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_group_id_user_id_key UNIQUE (group_id, user_id);


--
-- Name: group_members group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_pkey PRIMARY KEY (id);


--
-- Name: group_message_reads group_message_reads_group_message_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_message_reads
    ADD CONSTRAINT group_message_reads_group_message_id_user_id_key UNIQUE (group_message_id, user_id);


--
-- Name: group_message_reads group_message_reads_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_message_reads
    ADD CONSTRAINT group_message_reads_pkey PRIMARY KEY (id);


--
-- Name: group_messages group_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_messages
    ADD CONSTRAINT group_messages_pkey PRIMARY KEY (id);


--
-- Name: groups groups_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT groups_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: private_message_synced private_message_synced_message_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.private_message_synced
    ADD CONSTRAINT private_message_synced_message_id_user_id_key UNIQUE (message_id, user_id);


--
-- Name: private_message_synced private_message_synced_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.private_message_synced
    ADD CONSTRAINT private_message_synced_pkey PRIMARY KEY (id);


--
-- Name: server_settings server_settings_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.server_settings
    ADD CONSTRAINT server_settings_key_key UNIQUE (key);


--
-- Name: server_settings server_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.server_settings
    ADD CONSTRAINT server_settings_pkey PRIMARY KEY (id);


--
-- Name: user_relations user_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_relations
    ADD CONSTRAINT user_relations_pkey PRIMARY KEY (id);


--
-- Name: user_relations user_relations_user_id_friend_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_relations
    ADD CONSTRAINT user_relations_user_id_friend_id_key UNIQUE (user_id, friend_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: verification_codes verification_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification_codes
    ADD CONSTRAINT verification_codes_pkey PRIMARY KEY (id);


--
-- Name: idx_app_versions_platform; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_app_versions_platform ON public.app_versions USING btree (platform);


--
-- Name: idx_app_versions_platform_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_app_versions_platform_status ON public.app_versions USING btree (platform, status);


--
-- Name: idx_app_versions_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_app_versions_status ON public.app_versions USING btree (status);


--
-- Name: idx_device_installed_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_device_installed_at ON public.device_registrations USING btree (installed_at);


--
-- Name: idx_device_platform; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_device_platform ON public.device_registrations USING btree (platform);


--
-- Name: idx_device_uuid; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_device_uuid ON public.device_registrations USING btree (uuid);


--
-- Name: idx_favorite_contacts_contact_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorite_contacts_contact_id ON public.favorite_contacts USING btree (contact_id);


--
-- Name: idx_favorite_contacts_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorite_contacts_created_at ON public.favorite_contacts USING btree (created_at DESC);


--
-- Name: idx_favorite_contacts_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorite_contacts_user_id ON public.favorite_contacts USING btree (user_id);


--
-- Name: idx_favorite_groups_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorite_groups_created_at ON public.favorite_groups USING btree (created_at DESC);


--
-- Name: idx_favorite_groups_group_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorite_groups_group_id ON public.favorite_groups USING btree (group_id);


--
-- Name: idx_favorite_groups_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorite_groups_user_id ON public.favorite_groups USING btree (user_id);


--
-- Name: idx_favorites_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorites_created_at ON public.favorites USING btree (created_at DESC);


--
-- Name: idx_favorites_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_favorites_user_id ON public.favorites USING btree (user_id);


--
-- Name: idx_file_assistant_messages_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_file_assistant_messages_created_at ON public.file_assistant_messages USING btree (created_at DESC);


--
-- Name: idx_file_assistant_messages_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_file_assistant_messages_status ON public.file_assistant_messages USING btree (status);


--
-- Name: idx_file_assistant_messages_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_file_assistant_messages_user_id ON public.file_assistant_messages USING btree (user_id);


--
-- Name: idx_group_members_group_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_members_group_id ON public.group_members USING btree (group_id);


--
-- Name: idx_group_members_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_members_user_id ON public.group_members USING btree (user_id);


--
-- Name: idx_group_message_reads_group_message_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_message_reads_group_message_id ON public.group_message_reads USING btree (group_message_id);


--
-- Name: idx_group_message_reads_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_message_reads_user_id ON public.group_message_reads USING btree (user_id);


--
-- Name: idx_group_messages_call_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_messages_call_type ON public.group_messages USING btree (call_type) WHERE (call_type IS NOT NULL);


--
-- Name: idx_group_messages_channel_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_messages_channel_name ON public.group_messages USING btree (channel_name) WHERE (channel_name IS NOT NULL);


--
-- Name: idx_group_messages_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_messages_created_at ON public.group_messages USING btree (created_at);


--
-- Name: idx_group_messages_group_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_messages_group_id ON public.group_messages USING btree (group_id);


--
-- Name: idx_group_messages_sender_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_group_messages_sender_id ON public.group_messages USING btree (sender_id);


--
-- Name: idx_groups_owner_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_groups_owner_id ON public.groups USING btree (owner_id);


--
-- Name: idx_messages_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_created_at ON public.messages USING btree (created_at DESC);


--
-- Name: idx_messages_is_read; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_is_read ON public.messages USING btree (is_read) WHERE (is_read = false);


--
-- Name: idx_messages_receiver_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_receiver_id ON public.messages USING btree (receiver_id);


--
-- Name: idx_messages_receiver_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_receiver_name ON public.messages USING btree (receiver_name);


--
-- Name: idx_messages_sender_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_sender_id ON public.messages USING btree (sender_id);


--
-- Name: idx_messages_sender_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_sender_name ON public.messages USING btree (sender_name);


--
-- Name: idx_messages_sender_receiver; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_sender_receiver ON public.messages USING btree (sender_id, receiver_id, created_at DESC);


--
-- Name: idx_messages_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_messages_status ON public.messages USING btree (status);


--
-- Name: idx_user_relations_approval_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_relations_approval_status ON public.user_relations USING btree (approval_status);


--
-- Name: idx_user_relations_friend_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_relations_friend_id ON public.user_relations USING btree (friend_id);


--
-- Name: idx_user_relations_is_blocked; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_relations_is_blocked ON public.user_relations USING btree (is_blocked) WHERE (is_blocked = true);


--
-- Name: idx_user_relations_is_deleted; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_relations_is_deleted ON public.user_relations USING btree (is_deleted) WHERE (is_deleted = true);


--
-- Name: idx_user_relations_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_relations_user_id ON public.user_relations USING btree (user_id);


--
-- Name: idx_users_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_email ON public.users USING btree (email) WHERE (email IS NOT NULL);


--
-- Name: idx_users_invite_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_users_invite_code ON public.users USING btree (invite_code) WHERE (invite_code IS NOT NULL);


--
-- Name: idx_users_invited_by_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_invited_by_code ON public.users USING btree (invited_by_code) WHERE (invited_by_code IS NOT NULL);


--
-- Name: idx_users_phone; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_phone ON public.users USING btree (phone) WHERE (phone IS NOT NULL);


--
-- Name: idx_users_username; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_username ON public.users USING btree (username);


--
-- Name: idx_verification_codes_account; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_codes_account ON public.verification_codes USING btree (account);


--
-- Name: idx_verification_codes_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_codes_expires_at ON public.verification_codes USING btree (expires_at);


--
-- Name: server_settings update_server_settings_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_server_settings_updated_at BEFORE UPDATE ON public.server_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: favorite_contacts favorite_contacts_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_contacts
    ADD CONSTRAINT favorite_contacts_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: favorite_contacts favorite_contacts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_contacts
    ADD CONSTRAINT favorite_contacts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: favorite_groups favorite_groups_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_groups
    ADD CONSTRAINT favorite_groups_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE;


--
-- Name: favorite_groups favorite_groups_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorite_groups
    ADD CONSTRAINT favorite_groups_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: favorites favorites_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT favorites_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: favorites favorites_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT favorites_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id);


--
-- Name: favorites favorites_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.favorites
    ADD CONSTRAINT favorites_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: file_assistant_messages file_assistant_messages_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.file_assistant_messages
    ADD CONSTRAINT file_assistant_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: group_members group_members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE;


--
-- Name: group_members group_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: group_message_reads group_message_reads_group_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_message_reads
    ADD CONSTRAINT group_message_reads_group_message_id_fkey FOREIGN KEY (group_message_id) REFERENCES public.group_messages(id) ON DELETE CASCADE;


--
-- Name: group_message_reads group_message_reads_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_message_reads
    ADD CONSTRAINT group_message_reads_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: group_messages group_messages_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_messages
    ADD CONSTRAINT group_messages_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE;


--
-- Name: group_messages group_messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.group_messages
    ADD CONSTRAINT group_messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id);


--
-- Name: groups groups_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT groups_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: messages messages_receiver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_receiver_id_fkey FOREIGN KEY (receiver_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: messages messages_sender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_relations user_relations_friend_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_relations
    ADD CONSTRAINT user_relations_friend_id_fkey FOREIGN KEY (friend_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_relations user_relations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_relations
    ADD CONSTRAINT user_relations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: postgres
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;


--
-- PostgreSQL database dump complete
--

