# Build with the .NET 10 SDK (current LTS)
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Worker.csproj .
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release -o /app/publish

# Run on the .NET 10 runtime
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS runtime
WORKDIR /app

COPY --from=build /app/publish ./

# The database user and password come from the environment (Ansible sets them);
# Program.cs falls back to postgres/postgres when they are unset.
ENV DB_HOST=db
ENV DB_NAME=postgres
ENV REDIS_HOST=redis

# app (uid 1654, the image's APP_UID), the unprivileged user .NET images ship
USER 1654

# checkov:skip=CKV_DOCKER_2:the worker serves no port and the image has no curl; Docker's unless-stopped policy restarts it when it exits
ENTRYPOINT ["dotnet", "Worker.dll"]
