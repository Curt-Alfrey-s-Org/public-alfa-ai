import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import type { ReactNode } from "react";
import { api, ApiError } from "../api/client";
import type { User } from "../api/client";

interface AuthState {
  user: User | null;
  token: string | null;
  loading: boolean;
  login: (login: string, password: string) => Promise<LoginResult>;
  verify2FA: (tempToken: string, code: string) => Promise<void>;
  register: (email: string, username: string, password: string) => Promise<string>;
  logout: () => void;
}

type LoginResult = { ok: true } | { requires2FA: true; tempToken: string };

const AuthContext = createContext<AuthState | null>(null);

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used inside AuthProvider");
  return ctx;
}

const TOKEN_KEY = "change-me";
const REFRESH_KEY = "alfa_ai_refresh_token";

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [token, setToken] = useState<string | null>(() =>
    localStorage.getItem(TOKEN_KEY),
  );
  const [loading, setLoading] = useState(true);

  const persist = useCallback((access: string, refresh: string, u: User) => {
    localStorage.setItem(TOKEN_KEY, access);
    localStorage.setItem(REFRESH_KEY, refresh);
    setToken(access);
    setUser(u);
  }, []);

  const logout = useCallback(() => {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(REFRESH_KEY);
    setToken(null);
    setUser(null);
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const stored = localStorage.getItem(TOKEN_KEY);
      if (!stored) {
        setLoading(false);
        return;
      }
      try {
        const { user: u } = await api.me(stored);
        if (!cancelled) {
          setUser(u);
          setToken(stored);
        }
      } catch (err) {
        if (err instanceof ApiError && err.status === 401) {
          const refresh = localStorage.getItem(REFRESH_KEY);
          if (refresh) {
            try {
              const { access_token } = await api.refresh(refresh);
              const { user: u } = await api.me(access_token);
              if (!cancelled) persist(access_token, refresh, u);
              setLoading(false);
              return;
            } catch {
              /* refresh failed, fall through to logout */
            }
          }
          if (!cancelled) logout();
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const login = useCallback(
    async (login: string, password: string): Promise<LoginResult> => {
      const res = await api.login(login, password);
      if (res.requires_2fa && res.temp_token) {
        return { requires2FA: true, tempToken: res.temp_token };
      }
      persist(res.access_token!, res.refresh_token!, res.user!);
      return { ok: true };
    },
    [persist],
  );

  const verify2FA = useCallback(
    async (tempToken: string, code: string) => {
      const res = await api.verify2FA(tempToken, code);
      persist(res.access_token, res.refresh_token, res.user);
    },
    [persist],
  );

  const register = useCallback(
    async (email: string, username: string, password: string) => {
      // docs/AUTH_ACCOUNT_LIFECYCLE.md — register does not return a session.
      // Auto-login fails the verify/approval gates and paints success as an error.
      const res = await api.register(email, username, password);
      return res.message;
    },
    [],
  );

  const value = useMemo(
    () => ({ user, token, loading, login, verify2FA, register, logout }),
    [user, token, loading, login, verify2FA, register, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
