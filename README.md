# Sagasu backend

Spring Boot **4.1.1**, **Java 17**, Maven **3.9.9** (wrapper), and PostgreSQL **17**.

Dependencies: DevTools, Lombok, Spring Web MVC, SpringDoc OpenAPI **3.1.1**,
Spring Security, Spring Data JPA, Flyway (with PostgreSQL support), the PostgreSQL
driver, and Bean Validation. Actuator and development-time Compose support are
also included.

## Dependency setup notes

- Reload Maven in IntelliJ after pulling dependency changes. For Lombok, enable
  **Settings > Build, Execution, Deployment > Compiler > Annotation Processors >
  Enable annotation processing**. Install/enable the Lombok plugin if your IntelliJ
  version does not recognize generated methods.
- Swagger UI: <http://localhost:8080/swagger-ui/index.html>.
  OpenAPI JSON: <http://localhost:8080/v3/api-docs>.
  Spring Security's default login protects these endpoints: username `user`,
  password printed in the startup log as `Using generated security password`.
  This password changes at startup and is separate from the database password.
- Flyway migrations belong in `src/main/resources/db/migration`, using names such
  as `V1__create_users.sql`. No application migration has been added yet.
  Hibernate validates the schema; Flyway owns schema changes. Existing nonempty
  schemas without Flyway history need a deliberate baseline before migrations
  can run. Do not delete existing data to bypass that check.
- DevTools restarts the application when compiled classes change. In IntelliJ,
  use **Build > Build Project** after editing code to trigger a restart.

## First run in IntelliJ IDEA

Every teammate follows these steps once:

1. Install IntelliJ IDEA and Docker Desktop. On Windows, use Docker Desktop's
   WSL 2 backend and Linux containers. Start Docker Desktop and wait until its
   engine is running. No local PostgreSQL or Maven installation is needed.
2. Clone/download the project. In IntelliJ, choose **File > Open**, select
   `pom.xml`, and open it as a project. Trust the project if prompted.
3. Choose **File > Project Structure > Project > SDK > Download JDK**.
   Select **17** (Eclipse Temurin or Microsoft OpenJDK), then set the project
   SDK to that JDK and the language level to **SDK default**.
4. Under **Settings > Build, Execution, Deployment > Build Tools > Maven**,
   choose **Use Maven wrapper** for Maven home. Under **Importing**, select
   the project JDK for the importer; under **Runner**, select the project JDK
   for the JRE. Reload the project from the Maven tool window and wait for
   dependencies to finish downloading.
5. Select the shared **Sagasu Backend** run configuration in the top toolbar
   and click **Run** (or **Debug** for breakpoints). It runs
   `com.sagasu.SagasuApplication` with the project root as its working directory.
   If the configuration has not appeared yet, reload the project or use the
   green arrow beside `main` in `SagasuApplication.java`; set its working
   directory to the project root.
6. Wait for the application to report `Started SagasuApplication`. Open
   <http://localhost:8080/actuator/health>; a ready application and database
   return `{"status":"UP"}`.

Spring Boot's development-time Docker Compose support starts PostgreSQL and
waits for its health check automatically. The first run needs internet access
and can take several minutes to download Maven, dependencies, and the PostgreSQL
image. Subsequent runs reuse those downloads and the database volume.

The shared run configuration is a standard Java Application configuration and
uses the project SDK; it contains no developer-specific JDK paths.

## Daily workflow

Start Docker Desktop, open the project, and run **Sagasu Backend**.
PostgreSQL stays running when you stop the application, so debugging/restarting
is quick. To stop PostgreSQL manually without deleting its data:

```sh
docker compose stop postgres
```

## Run from a terminal

Install JDK 17 and set `JAVA_HOME` to its installation directory.
With Docker Desktop running, from the project root:

Windows PowerShell:

```powershell
.\mvnw.cmd spring-boot:run
```

macOS/Linux:

```sh
sh ./mvnw spring-boot:run
```

Both commands download the pinned Maven version automatically and start
PostgreSQL through Spring Boot. The wrapper comes from Apache Maven Wrapper
3.3.4 and supports Windows, macOS, and Linux.

## Database connection

| Setting | Value |
| --- | --- |
| Host | `localhost` |
| Port | `5432` |
| Database | `sagasu_db` |
| Username | `postgres` |
| Password | `postgres` |
| JDBC URL | `jdbc:postgresql://localhost:5432/sagasu_db` |

These are local development credentials. Data is stored in a persistent Docker
volume. You can connect using IntelliJ's database tools or any PostgreSQL client,
or use the container's psql:

```sh
docker compose exec postgres psql -U postgres -d sagasu_db
```

## Build

Windows:

```powershell
.\mvnw.cmd clean verify
```

macOS/Linux:

```sh
sh ./mvnw clean verify
```

The build does not need a running database. There are no application tests or
business endpoints yet. To run the packaged application, start PostgreSQL first:

```sh
docker compose up -d --wait postgres
java -jar target/sagasu-be-0.0.1-SNAPSHOT.jar
```

Spring Boot excludes development-time Compose support from the packaged JAR.

## Docker-only alternative

Without installing Java or Maven locally:

```sh
docker compose run --rm maven
docker compose up -d --wait postgres
docker compose run --rm --service-ports maven mvn --batch-mode spring-boot:run
```

The Maven container connects to `postgres:5432` and disables Spring Boot's
Compose management because Docker is managed from the host.

## Troubleshooting

- **Docker connection error:** start Docker Desktop, then check `docker info`
  and `docker compose version` in IntelliJ's terminal. If Docker was installed
  while IntelliJ was open, restart IntelliJ so it gets the updated PATH.
- **Unsupported Java/class-file version:** check the project SDK, Maven importer,
  and Maven runner all use JDK 17. `JAVA_HOME` controls terminal runs; run
  `.\mvnw.cmd -version` (Windows) or `sh ./mvnw -version` (macOS/Linux) to check.
- **Port 5432 already allocated:** stop the other local PostgreSQL/container,
  or change the Compose mapping to `127.0.0.1:5433:5432`. During development,
  Spring Boot discovers the mapped port automatically. Packaged JARs need
  `SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5433/sagasu_db`.
- **Port 8080 already allocated:** stop the other app or set `SERVER_PORT=8081`
  in the run configuration's environment variables.
- **Compose file not found:** set the run configuration's working directory to
  the folder containing `pom.xml` and `compose.yaml`.
- **Dependency/download failure:** check internet access and your team's
  proxy/Maven mirror settings, then reload Maven.
- **Authentication fails after changing credentials:** an existing PostgreSQL
  volume retains its original credentials. Restore the old credentials or,
  only if local data can be discarded, run `docker compose down -v` and restart.
  This deletes the local database and Maven cache volumes.
- **Database `sagasu_db` does not exist:** `POSTGRES_DB` creates the database
  only when the Docker data volume is first initialized. If you already have
  a volume from an earlier setup, preserve its data and create the database once:
  `docker compose exec postgres createdb -U postgres sagasu_db`.

## Files to share with the team

Commit/share `pom.xml`, `src/`, `compose.yaml`, `mvnw`, `mvnw.cmd`, `.mvn/`,
`.run/`, `.gitattributes`, `.gitignore`, and this README. `.idea/` and `target/`
are ignored because they contain local IDE settings and generated build files.

References: [Spring Boot Compose support](https://docs.spring.io/spring-boot/reference/features/dev-services.html),
[Apache Maven Wrapper](https://maven.apache.org/tools/wrapper/), and
[IntelliJ shared run configurations](https://www.jetbrains.com/help/idea/run-debug-configuration.html).
