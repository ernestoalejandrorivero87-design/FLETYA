-- Prevent direct unquoted job creation by application users.
-- Authorized postgres-owned SECURITY DEFINER booking functions retain access.
REVOKE INSERT ON public.jobs FROM authenticated, anon;
