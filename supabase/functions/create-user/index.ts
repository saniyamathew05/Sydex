import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  try {
    if (req.method !== "POST") {
      return jsonResponse(
        { error: "Method not allowed." },
        405,
      );
    }

    const contentLength = Number(req.headers.get("content-length") ?? "0");
    if (contentLength > 64_000) {
      return jsonResponse({ error: "Request is too large." }, 413);
    }

    const supabaseUrl =
      Deno.env.get("SUPABASE_URL");

    const serviceRoleKey =
      Deno.env.get(
        "SUPABASE_SERVICE_ROLE_KEY",
      );

    const anonKey =
      Deno.env.get("SUPABASE_ANON_KEY");

    if (
      !supabaseUrl ||
      !serviceRoleKey ||
      !anonKey
    ) {
      throw new Error(
        "Supabase server configuration is missing.",
      );
    }

    const authHeader =
      req.headers.get("Authorization");

    if (!authHeader) {
      return jsonResponse(
        {
          error:
            "You must be logged in.",
        },
        401,
      );
    }

    /*
     * Client using the currently logged-in
     * user's JWT.
     */
    const userClient = createClient(
      supabaseUrl,
      anonKey,
      {
        global: {
          headers: {
            Authorization: authHeader,
          },
        },
      },
    );

    const {
      data: {
        user,
      },
      error: userError,
    } = await userClient.auth.getUser();

    if (userError || !user) {
      return jsonResponse(
        {
          error:
            "Invalid or expired login session.",
        },
        401,
      );
    }

    /*
     * Admin client.
     *
     * Service role stays inside the Edge
     * Function and never enters Flutter.
     */
    const admin = createClient(
      supabaseUrl,
      serviceRoleKey,
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
        },
      },
    );

    /*
     * Verify requester is an owner.
     */
    const {
      data: requesterProfile,
      error: requesterError,
    } = await admin
      .from("profiles")
      .select("role, company_id")
      .eq("id", user.id)
      .maybeSingle();

    if (requesterError) {
      throw requesterError;
    }

    if (
      !requesterProfile ||
      String(requesterProfile.role ?? "").toLowerCase() !== "owner"
    ) {
      return jsonResponse(
        {
          error:
            "Only owners can manage users.",
        },
        403,
      );
    }

    if (!requesterProfile.company_id) {
      return jsonResponse({ error: "Your account is not linked to a company." }, 409);
    }

    const body = await req.json();

    const action =
      typeof body.action === "string"
        ? body.action
            .trim()
            .toLowerCase()
        : "create";

    /*
     * =====================================================
     * CREATE USER
     * =====================================================
     */
    if (action === "create") {
      const email =
        typeof body.email === "string"
          ? body.email
              .trim()
              .toLowerCase()
          : "";

      const password =
        typeof body.password === "string"
          ? body.password
          : "";

      const name =
        typeof body.name === "string"
          ? body.name.trim()
          : "";

      const role =
        typeof body.role === "string"
          ? body.role
              .trim()
              .toLowerCase()
          : "";

      if (
        !email ||
        !password ||
        !name ||
        !role
      ) {
        return jsonResponse(
          {
            error:
              "Name, email, password and role are required.",
          },
          400,
        );
      }

      if (
        role !== "owner" &&
        role !== "salesman"
      ) {
        return jsonResponse(
          {
            error:
              "Role must be owner or salesman.",
          },
          400,
        );
      }

      if (password.length < 12) {
        return jsonResponse(
          {
            error:
              "Password must contain at least 12 characters.",
          },
          400,
        );
      }

      const {
        data: createdUser,
        error: createUserError,
      } =
        await admin.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
        });

      if (createUserError) {
        return jsonResponse(
          {
            error:
              createUserError.message,
          },
          400,
        );
      }

      if (!createdUser.user) {
        throw new Error(
          "User account could not be created.",
        );
      }

      const {
        error: profileError,
      } = await admin
        .from("profiles")
        .insert({
          id: createdUser.user.id,
          name,
          role,
          company_id: requesterProfile.company_id,
        });

      if (profileError) {
        await admin.auth.admin.deleteUser(
          createdUser.user.id,
        );

        throw profileError;
      }

      const { error: membershipError } = await admin
        .from("company_members")
        .insert({
          company_id: requesterProfile.company_id,
          user_id: createdUser.user.id,
          role,
        });

      if (membershipError) {
        await admin.from("profiles").delete().eq("id", createdUser.user.id);
        await admin.auth.admin.deleteUser(createdUser.user.id);
        throw membershipError;
      }

      return jsonResponse(
        {
          success: true,
          user: {
            id: createdUser.user.id,
            email:
              createdUser.user.email,
            name,
            role,
          },
        },
        201,
      );
    }

    /*
     * =====================================================
     * UPDATE USER
     * =====================================================
     */
    if (action === "update") {
      const userId =
        typeof body.userId === "string"
          ? body.userId.trim()
          : "";

      const name =
        typeof body.name === "string"
          ? body.name.trim()
          : "";

      const role =
        typeof body.role === "string"
          ? body.role
              .trim()
              .toLowerCase()
          : "";

      const password =
        typeof body.password === "string"
          ? body.password
          : "";

      if (!userId) {
        return jsonResponse(
          {
            error:
              "User ID is required.",
          },
          400,
        );
      }

      if (!name) {
        return jsonResponse(
          {
            error:
              "Name is required.",
          },
          400,
        );
      }

      if (
        role !== "owner" &&
        role !== "salesman"
      ) {
        return jsonResponse(
          {
            error:
              "Role must be owner or salesman.",
          },
          400,
        );
      }

      /*
       * Prevent an owner from changing
       * their own role.
       */
      if (
        userId === user.id &&
        role !== "owner"
      ) {
        return jsonResponse(
          {
            error:
              "You cannot remove your own owner role.",
          },
          400,
        );
      }

      /*
       * Prevent changing your own password
       * through this admin screen.
       */
      if (
        userId === user.id &&
        password.length > 0
      ) {
        return jsonResponse(
          {
            error:
              "Use account security settings to change your own password.",
          },
          400,
        );
      }

      const { data: targetProfile, error: targetProfileError } = await admin
        .from("profiles")
        .select("id, company_id")
        .eq("id", userId)
        .maybeSingle();
      if (targetProfileError) throw targetProfileError;
      if (!targetProfile || targetProfile.company_id !== requesterProfile.company_id) {
        return jsonResponse({ error: "That user belongs to another company." }, 403);
      }

      /*
       * Update profile.
       */
      const {
        error: updateProfileError,
      } = await admin
        .from("profiles")
        .update({
          name,
          role,
        })
        .eq("id", userId);

      if (updateProfileError) {
        throw updateProfileError;
      }

      const { error: updateMembershipError } = await admin
        .from("company_members")
        .update({ role })
        .eq("company_id", requesterProfile.company_id)
        .eq("user_id", userId);
      if (updateMembershipError) throw updateMembershipError;

      /*
       * Update Auth password when provided.
       */
      if (password.length > 0) {
        if (password.length < 12) {
          return jsonResponse(
            {
              error:
                "Password must contain at least 12 characters.",
            },
            400,
          );
        }

        const {
          error: passwordError,
        } =
          await admin.auth.admin.updateUserById(
            userId,
            {
              password,
            },
          );

        if (passwordError) {
          throw passwordError;
        }
      }

      return jsonResponse(
        {
          success: true,
          message:
            "User updated successfully.",
        },
        200,
      );
    }

    /*
     * =====================================================
     * DELETE USER
     * =====================================================
     */
    if (action === "delete") {
      const userId =
        typeof body.userId === "string"
          ? body.userId.trim()
          : "";

      if (!userId) {
        return jsonResponse(
          {
            error:
              "User ID is required.",
          },
          400,
        );
      }

      if (userId === user.id) {
        return jsonResponse(
          {
            error:
              "You cannot delete your own account.",
          },
          400,
        );
      }

      const {
        data: targetProfile,
        error: targetError,
      } = await admin
        .from("profiles")
        .select(
          "id, name, role, company_id",
        )
        .eq("id", userId)
        .maybeSingle();

      if (targetError) {
        throw targetError;
      }

      if (!targetProfile) {
        return jsonResponse(
          {
            error:
              "User profile was not found.",
          },
          404,
        );
      }

      if (targetProfile.company_id !== requesterProfile.company_id) {
        return jsonResponse({ error: "That user belongs to another company." }, 403);
      }

      const {
        error: deleteError,
      } =
        await admin.auth.admin.deleteUser(
          userId,
        );

      if (deleteError) {
        throw deleteError;
      }

      return jsonResponse(
        {
          success: true,
          message:
            `${targetProfile.name} was deleted.`,
        },
        200,
      );
    }

    return jsonResponse(
      {
        error:
          "Unknown action.",
      },
      400,
    );
  } catch (error) {
    console.error(
      "create-user error:",
      error,
    );

    return jsonResponse(
      {
        error:
          error instanceof Error
            ? error.message
            : "An unexpected error occurred.",
      },
      500,
    );
  }
});

function jsonResponse(
  data: Record<string, unknown>,
  status: number,
) {
  return new Response(
    JSON.stringify(data),
    {
      status,
      headers: {
        ...corsHeaders,
        "Content-Type":
          "application/json",
      },
    },
  );
}
