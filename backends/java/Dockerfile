# ---- build: compile and TEST (tests run on every image build) ---------------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

# Dependencies as their own layer: unchanged pom.xml => cached, no re-download.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -q dependency:go-offline

COPY src ./src
# No -DskipTests: building the image IS the verification.
RUN --mount=type=cache,target=/root/.m2 mvn -q package

# ---- runtime: JRE only, non-root --------------------------------------------
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S spring && adduser -S spring -G spring
WORKDIR /app
USER spring
COPY --from=build /build/target/java-message-server-1.0.0.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
