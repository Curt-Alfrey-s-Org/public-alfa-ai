import { Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider, useAuth } from "./contexts/AuthContext";
import Login from "./pages/Login";
import Register from "./pages/Register";
import Chat from "./pages/Chat";
import Setup2FA from "./pages/Setup2FA";
import GuestChat from "./pages/GuestChat";
import AdminLayout from "./pages/admin/AdminLayout";
import HealthPage from "./pages/admin/HealthPage";
import IncidentsPage from "./pages/admin/IncidentsPage";
import MissionsPage from "./pages/admin/MissionsPage";
import AiActionsPage from "./pages/admin/AiActionsPage";
import ModelsPage from "./pages/admin/ModelsPage";
import EditorPage from "./pages/admin/EditorPage";
import UsersPage from "./pages/admin/UsersPage";
import AuditPage from "./pages/admin/AuditPage";
import AccountPassword from "./pages/AccountPassword";
import AboutPage from "./pages/AboutPage";
import ManualPage from "./pages/ManualPage";
import VerifyEmail from "./pages/VerifyEmail";

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();
  if (loading) {
    return (
      <div className="flex h-screen items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-2 border-sky-500 border-t-transparent" />
      </div>
    );
  }
  if (!user) return <Navigate to="/login" replace />;
  return <>{children}</>;
}

function AdminRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();
  if (loading) return null;
  if (!user) return <Navigate to="/login" replace />;
  if (user.is_admin !== true) return <Navigate to="/" replace />;
  return <>{children}</>;
}

function GuestRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();
  if (loading) return null;
  if (user) return <Navigate to="/" replace />;
  return <>{children}</>;
}

export default function App() {
  return (
    <AuthProvider>
      <Routes>
        <Route path="/guest" element={<GuestChat />} />
        <Route
          path="/login"
          element={<GuestRoute><Login /></GuestRoute>}
        />
        <Route
          path="/register"
          element={<GuestRoute><Register /></GuestRoute>}
        />
        <Route
          path="/setup-2fa"
          element={<ProtectedRoute><Setup2FA /></ProtectedRoute>}
        />
        <Route path="/about" element={<AboutPage />} />
        <Route path="/manual" element={<ManualPage />} />
        <Route path="/verify-email" element={<VerifyEmail />} />
        <Route
          path="/account/password"
          element={<ProtectedRoute><AccountPassword /></ProtectedRoute>}
        />
        <Route
          path="/admin"
          element={<AdminRoute><AdminLayout /></AdminRoute>}
        >
          <Route index element={<Navigate to="health" replace />} />
          <Route path="health" element={<HealthPage />} />
          <Route path="incidents" element={<IncidentsPage />} />
          <Route path="missions" element={<MissionsPage />} />
          <Route path="ai-actions" element={<AiActionsPage />} />
          <Route path="models" element={<ModelsPage />} />
          <Route path="editor" element={<EditorPage />} />
          <Route path="users" element={<UsersPage />} />
          <Route path="audit" element={<AuditPage />} />
          <Route path="manual" element={<Navigate to="/manual#admin-console" replace />} />
        </Route>
        <Route
          path="/"
          element={<ProtectedRoute><Chat /></ProtectedRoute>}
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AuthProvider>
  );
}
