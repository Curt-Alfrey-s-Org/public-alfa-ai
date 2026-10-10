import { useEffect } from "react";
import { Link, useLocation } from "react-router-dom";
import { ModelTierList } from "../content/modelHosts";

const sections = [
  {
    id: "platform",
    title: "What runs ALFa AI",
    body: [
      "Private Alfa Quantum Dynamics infrastructure — not ChatGPT or other public cloud bots.",
      "A dedicated routing service picks the best model tier for each request.",
      "Your chats stay on our network.",
    ],
  },
  {
    id: "start",
    title: "How to start",
    body: [
      "Pick a model from the menu in the chat header (default is fine for most questions).",
      "Type your message at the bottom and press Send.",
      "After a reply, hover your message and click Edit to change it and get a new answer.",
    ],
  },
  {
    id: "models",
    title: "Smartest to simplest",
    showTierList: true,
  },
] as const;

export default function AboutPage() {
  const { hash } = useLocation();

  useEffect(() => {
    if (!hash) return;
    const el = document.querySelector(hash);
    el?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [hash]);

  return (
    <div className="min-h-screen bg-slate-950 text-slate-200">
      <header className="border-b border-slate-800 bg-slate-900/80 px-4 py-3 backdrop-blur">
        <div className="mx-auto flex max-w-2xl items-center justify-between">
          <Link to="/" className="text-sm font-semibold text-sky-400 hover:text-sky-300">
            Back to chat
          </Link>
          <span className="text-sm text-slate-500">About ALFa AI</span>
        </div>
      </header>

      <main className="mx-auto max-w-2xl px-4 py-10">
        <h1 className="text-2xl font-bold text-slate-100">About ALFa AI</h1>
        <p className="mt-2 text-sm text-slate-500">
          Short guide for customers. Pick a topic below or jump from the chat screen.
        </p>

        <nav className="mt-6 flex flex-wrap gap-2">
          {sections.map((s) => (
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
          {sections.map((s) => (
            <section key={s.id} id={s.id} className="scroll-mt-6">
              <h2 className="text-lg font-semibold text-slate-200">{s.title}</h2>
              {"showTierList" in s && s.showTierList ? (
                <>
                  <p className="mt-2 text-sm text-slate-500">
                    Higher rank = smarter and slower. Start in the middle unless you need max quality or speed.
                  </p>
                  <ModelTierList />
                </>
              ) : (
                <ul className="mt-3 space-y-2 text-sm leading-relaxed text-slate-400">
                  {"body" in s &&
                    s.body.map((line) => (
                      <li key={line} className="flex gap-2">
                        <span className="text-slate-600">-</span>
                        <span>{line}</span>
                      </li>
                    ))}
                </ul>
              )}
            </section>
          ))}
        </div>
      </main>
    </div>
  );
}
