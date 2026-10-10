import { NavLink, Outlet, Link } from "react-router-dom";
import AskAlfaWidget from "../../components/admin/AskAlfaWidget";
import OperationalAlertsBanner from "../../components/admin/OperationalAlertsBanner";
import { useAuth } from "../../contexts/AuthContext";

const tabs = [
  { to: "/admin/health", label: "Health" },
  { to: "/admin/incidents", label: "Monitoring" },
  { to: "/admin/missions", label: "Missions" },
  { to: "/admin/ai-actions", label: "AI Actions" },
  { to: "/admin/models", label: "Models" },
  { to: "/admin/editor", label: "Editor" },
  { to: "/admin/users", label: "Users" },
  { to: "/admin/audit", label: "Audit Log" },
];

export default function AdminLayout() {
  const { token } = useAuth();

  return (
    <div className="flex h-screen flex-col">
      <header className="flex items-center gap-4 border-b border-slate-800 bg-slate-900/80 px-4 py-2 backdrop-blur">
        <NavLink to="/" className="flex items-center gap-2 text-lg font-bold text-sky-400">
          <img src="/alfa-ai/branding/alfa-ai-avatar.png" alt="ALFa AI" className="h-6 w-6 rounded-full object-cover" />
          ALFa AI
        </NavLink>
        <span className="text-xs text-slate-600">|</span>
        <span className="text-sm font-medium text-slate-300">Admin</span>
        <nav className="ml-4 flex gap-1">
          {tabs.map((t) => (
            <NavLink
              key={t.to}
              to={t.to}
              className={({ isActive }) =>
                `rounded-lg px-3 py-1.5 text-xs font-medium transition ${
                  isActive
                    ? "bg-sky-600 text-white"
                    : "text-slate-400 hover:bg-slate-800 hover:text-slate-200"
                }`
              }
            >
              {t.label}
            </NavLink>
          ))}
          <Link
            to="/manual#admin-console"
            className="rounded-lg px-3 py-1.5 text-xs font-medium text-slate-400 transition hover:bg-slate-800 hover:text-slate-200"
          >
            Manual
          </Link>
        </nav>
        <div className="flex-1" />
        <NavLink
          to="/"
          className="rounded-lg border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-300"
        >
          Back to Chat
        </NavLink>
      </header>
      {token && <OperationalAlertsBanner token={token} />}
      <div className="flex-1 overflow-hidden">
        <Outlet />
      </div>
      <AskAlfaWidget />
    </div>
  );
}
