package com.sagasu;

import java.util.TimeZone;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class SagasuApplication {
    public static void main(String[] args) {
        // JDBC sends the JVM timezone when connecting, before Spring config runs.
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
        SpringApplication.run(SagasuApplication.class, args);
    }
}
