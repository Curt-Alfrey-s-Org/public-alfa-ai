import { useEffect } from "react";
import { Link, useLocation } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import {
  adminManualSections,
  userManualSections,
  type ManualSection,
} from "../content/manualSections";

function SectionBlock({ section }: { section: ManualSection }) {
  return (
    <section key={section.id} id={section.id} className="scroll-mt-6">
      <h2 className="text-lg font-semibold text-slate-200">{section.title}</h2>
      <ul className="mt-3 space-y-2 text-sm leading-relaxed text-slate-400">
        {section.body.map((line) => (
          <li key={line} className="flex gap-2">
            <span className="text-slate-600">-</span>
            <span>{line}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export default function ManualPage() {
  const { hash } = useLocation();
  const { user, loading } = useAuth();
  const isAdmin = user?.is_admin === true;
  const navSections = isAdmin
    ? [...userManualSections, ...adminManualSections]
    : userManualSections;

  useEffect(() => {
    if (!hash) return;
    const el = document.querySelector(hash);
    el?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [hash, isAdmin, loading]);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-200">
      <header className="border-b border-slate-800 bg-slate-900/80 px-4 py-3 backdrop-blur">
        <div className="mx-auto flex max-w-2xl items-center justify-between">
          <Link to="/" className="text-sm font-semibold text-sky-400 hover:text-sky-300">
            Back to chat
          </Link>
          <span className="text-sm text-slate-500">Users Manual</span>
        </div>
      </header>

      <main className="mx-auto max-w-2xl px-4 py-10">
        <h1 className="text-2xl font-bold text-slate-100">Users Manual</h1>
        <p className="mt-2 text-sm text-slate-500">
          How to use ALFa AI chat. Jump to a topic below.
          {isAdmin ? " Admin console topics appear at the bottom." : ""}
        </p>

        <nav className="mt-6 flex flex-wrap gap-2">
          {navSections.map((s) => (
            <a
              key={s.id}
              href={`#${s.id}`}
              className="rounded-full border border-slate-700 bg-slate-900 px-3 py-1 text-xs text-slate-400 transition hover:border-slate-600 hover:text-slate-200"
            >
              {s.title}
            </a>
          ))}
        </nav>

        <div className="mt-10 space-y-10">
          {userManualSections.map((s) => (
            <SectionBlock key={s.id} section={s} />
          ))}
        </div>

        {!loading && isAdmin && (
          <div className="mt-14 border-t border-slate-800 pt-10">
            <h2 className="text-xl font-bold text-slate-100">Admin</h2>
            <p className="mt-2 text-sm text-slate-500">
              Visible only to admin accounts. Open the full console from the Admin link in chat.
            </p>
            <div className="mt-8 space-y-10">
              {adminManualSections.map((s) => (
                <SectionBlock key={s.id} section={s} />
              ))}
            </div>
            <p className="mt-8">
              <Link
                to="/admin/health"
                className="text-sm font-medium text-sky-400 hover:text-sky-300"
              >
                Open Admin console →
              </Link>
            </p>
          </div>
        )}
      </main>
    </div>
  );
}
